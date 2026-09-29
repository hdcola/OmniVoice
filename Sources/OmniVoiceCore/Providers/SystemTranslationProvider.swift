import Foundation

/// One buffered translation request, ready for a SwiftUI view's
/// `.translationTask` to translate — `TranslationSession` can only be
/// obtained inside a SwiftUI view (a platform constraint, not a design
/// choice this app can route around), so `SystemTranslationProvider` itself
/// can never call `TranslationSession.translate(_:)` directly.
public struct TranslationBridgeRequest: Identifiable, Sendable {
    public let id: UUID
    public let text: String
    /// Whether this request corresponds to a real `flush()` (an ASR segment
    /// boundary) — `false` for an `earlyTranslateThreshold`-driven early
    /// translation of a still-open segment's buffer (see
    /// `SystemTranslationProvider.feed(_:)`'s doc). `receiveResult(_:isFinal:)`
    /// reads this back (via `resolveTranslationBridgeResult(_:isFinal:)`) to
    /// decide whether to fire `onFlushBoundary` — an early, non-final commit
    /// must append into the segment's still-open translation row, not close
    /// it, the same distinction T3PO's forced-probe-vs-real-flush already
    /// makes.
    public let isFinal: Bool

    public init(id: UUID = UUID(), text: String, isFinal: Bool = true) {
        self.id = id
        self.text = text
        self.isFinal = isFinal
    }
}

/// Adapts macOS's on-device `Translation` framework (one-shot
/// request/response) to the same `feed`/`flush` shape a genuinely streaming
/// engine uses — see `TranslationProvider`'s doc. `feed(_:)` mostly just
/// accumulates; `flush()` is the usual point a translation happens, though
/// `feed(_:)` itself may trigger an early one too — see its own doc and
/// `TranslationConfig.earlyTranslateThreshold`'s.
///
/// Deliberately does **not** own the bridge to a SwiftUI `.translationTask`
/// itself (unlike an earlier version of this file) — `RecordingSession`
/// creates a fresh provider instance on every `start()`, but the actual
/// `AsyncStream` a `.translationTask` drains needs to survive across
/// stop/start cycles whenever the SwiftUI view hosting it doesn't remount
/// (exactly `mac-poc-hybrid`'s `AppModel.makeTranslationRequests()`
/// situation: the continuation is long-lived, only *which* provider feeds
/// into it changes per run). So the continuation lives on
/// `RecordingSession`, threaded down to whichever `SystemTranslationProvider`
/// is current via `onBridgeRequest`, set fresh each `start()`.
///
/// Ported/adapted from `mac-poc-hybrid`'s native-translation wiring in
/// `AppModel` (`makeTranslationRequests()` / `submitNativeTranslationRequestIfNeeded`).
public final class SystemTranslationProvider: TranslationProvider {
    public var onCommit: ((String) -> Void)?
    public var onPreview: ((String) -> Void)? // never called — no-op preview, see the protocol's doc.
    public var onFlushBoundary: (() -> Void)?
    /// Set by `RecordingSession` at `start()` — forwards each flushed buffer
    /// to whatever long-lived bridge stream is currently listening.
    public var onBridgeRequest: ((TranslationBridgeRequest) -> Void)?

    private var buffer = ""
    private var config: TranslationConfig?
    /// How many bridge requests have been sent (via `onBridgeRequest`) but
    /// not yet resolved (via `receiveResult(_:isFinal:)`) — see
    /// `sendBridgeRequest(isFinal:)`'s doc for why this matters: without it,
    /// a `flush()` that finds an empty buffer (because an earlier
    /// `earlyTranslateThreshold`-driven request already drained it) would
    /// fire `onFlushBoundary` — advancing `translationRowIndex` — *before*
    /// that earlier request's result ever arrives, misrouting it into the
    /// next segment's row instead.
    private var pendingBridgeRequestCount = 0
    /// Set instead of firing `onFlushBoundary` immediately when `flush()`
    /// finds an empty buffer while `pendingBridgeRequestCount > 0` — cleared
    /// and actually fired from `receiveResult(_:isFinal:)` once every
    /// already-sent request has resolved.
    ///
    /// Known remaining gap: if the *next* segment starts (`feed(_:)` is
    /// called again) and itself crosses `earlyTranslateThreshold` before the
    /// deferred boundary above actually fires, that new segment's early
    /// request resolves into the still-current (old) row — its `onCommit`
    /// runs before `pendingFlushBoundary` is checked — rather than the new
    /// one, since `translationRowIndex` hasn't advanced yet. This needs
    /// back-to-back speech with essentially no pause across the segment
    /// boundary to hit; tagging each request with which segment it belongs
    /// to would close it fully, but that's a bigger change than this fix
    /// warrants for how narrow the window is.
    private var pendingFlushBoundary = false

    public init() {}

    public func loadModel() async throws {}
    public func unload() {}

    public func start(config: TranslationConfig) async throws {
        self.config = config
        buffer = ""
    }

    public func updateEarlyTranslateThreshold(_ characters: Int) {
        config?.earlyTranslateThreshold = characters
    }

    /// Appends `text` — and, once `buffer` crosses half of
    /// `config.earlyTranslateThreshold` *and* `text` itself ends a sentence,
    /// sends an early, non-final bridge request rather than cutting
    /// mid-sentence purely by length; crossing the full
    /// `earlyTranslateThreshold` sends one regardless of punctuation (see
    /// `TranslationConfig.earlyTranslateThreshold`'s doc for the full
    /// reasoning: a single long, pause-free utterance shouldn't leave the
    /// user waiting for a translation, or waiting on a large block of text
    /// all at once, until the speaker finally stops). Reuses the same
    /// `onBridgeRequest`/"no bridge attached yet" handling `flush()` uses,
    /// just with `isFinal: false` — see `TranslationBridgeRequest.isFinal`'s
    /// doc for what that changes.
    public func feed(_ text: String) {
        buffer += text
        guard let threshold = config?.earlyTranslateThreshold else { return }
        let crossedHardCap = buffer.count >= threshold
        let crossedSoftBreak = buffer.count >= threshold / 2 && SentenceBoundary.endsSentence(text)
        guard crossedHardCap || crossedSoftBreak else { return }
        sendBridgeRequest(isFinal: false)
    }

    /// Unlike a streaming engine (where a forced probe commits synchronously,
    /// inline in `flush()`), the actual translation here only happens later,
    /// asynchronously, once the bridging view's `.translationTask` picks up
    /// the yielded request — so `onFlushBoundary` must **not** fire here.
    /// Firing it immediately would violate `TranslationProvider`'s own
    /// contract ("no more `onCommit` calls belong to text fed before this
    /// flush"): `RecordingSession.advanceTranslationRow()` would advance to
    /// the next row before this row's translation ever arrived, permanently
    /// misaligning every row after it and persisting an empty
    /// `translationText`. The boundary instead fires from
    /// `receiveResult(_:isFinal:)`, once the commit it belongs to has
    /// actually happened.
    ///
    /// If nothing is buffered *and nothing else is still in flight*, there's
    /// nothing to wait on, so the boundary fires immediately. If the buffer
    /// is only empty because an earlier `earlyTranslateThreshold`-driven
    /// request already drained it, the same reasoning applies to *that*
    /// request too — see `sendBridgeRequest(isFinal:)`'s doc for how that
    /// case is deferred instead of misrouting the pending result.
    public func flush() {
        sendBridgeRequest(isFinal: true)
    }

    /// Shared by `flush()` (`isFinal: true`) and `feed(_:)`'s
    /// `earlyTranslateThreshold`-driven early translation (`isFinal:
    /// false`) — see `TranslationBridgeRequest.isFinal`'s doc for what that
    /// flag changes downstream.
    ///
    /// A **final** call with an empty buffer needs special care: the buffer
    /// can be empty either because nothing was ever fed (the common case —
    /// safe to fire `onFlushBoundary` immediately), or because an earlier
    /// `earlyTranslateThreshold`-driven request already drained it and
    /// hasn't resolved yet (`pendingBridgeRequestCount > 0`) — firing the
    /// boundary in that second case would advance `translationRowIndex`
    /// before that request's result arrives, misrouting it into the next
    /// segment's row once it finally does. `pendingFlushBoundary` defers to
    /// `receiveResult(_:isFinal:)` in exactly that case.
    private func sendBridgeRequest(isFinal: Bool) {
        guard !buffer.isEmpty else {
            guard isFinal else { return } // nothing buffered, nothing to send early
            if pendingBridgeRequestCount > 0 {
                pendingFlushBoundary = true
            } else {
                onFlushBoundary?()
            }
            return
        }
        let text = buffer
        buffer = ""
        guard let onBridgeRequest else {
            // No bridging view attached yet (e.g. the floating panel hasn't
            // been created) — there is nowhere for this request to go and
            // nothing will ever call `receiveResult(_:isFinal:)` for it. For
            // a final request, firing the boundary anyway loses this one
            // row's translation, but *not* firing it would permanently
            // stall `translationRowIndex` and misalign every row after it —
            // losing one translation is the smaller failure. For a
            // non-final (early) request there's no row to close in the
            // first place, so there's nothing to do but drop it.
            if isFinal { onFlushBoundary?() }
            return
        }
        pendingBridgeRequestCount += 1
        onBridgeRequest(TranslationBridgeRequest(text: text, isFinal: isFinal))
    }

    public func stop() async {}

    /// Called by the bridging view once a request's `translate(_:)`
    /// resolves — this, not `flush()`, is what actually marks a row's
    /// translation as done, and only for a **final** result (see `flush()`'s
    /// doc and `TranslationBridgeRequest.isFinal`'s doc) — a non-final
    /// (early, `earlyTranslateThreshold`-driven) result still commits its
    /// text into the segment's still-open row, it just doesn't close it,
    /// *unless* an earlier `flush()` already deferred its boundary to this
    /// point (`pendingFlushBoundary`, see `sendBridgeRequest(isFinal:)`'s
    /// doc) — once every outstanding request has resolved
    /// (`pendingBridgeRequestCount` back at zero), the deferred boundary
    /// fires here instead.
    public func receiveResult(_ text: String, isFinal: Bool) {
        pendingBridgeRequestCount = max(0, pendingBridgeRequestCount - 1)
        onCommit?(text)
        if isFinal {
            onFlushBoundary?()
        } else if pendingFlushBoundary && pendingBridgeRequestCount == 0 {
            pendingFlushBoundary = false
            onFlushBoundary?()
        }
    }

    public var currentSourceLanguageCode: String? { config?.sourceLanguageCode }
    public var currentTargetLanguageCode: String? { config?.targetLanguageCode ?? "" }
}
