import Foundation

/// One buffered translation request, ready for a SwiftUI view's
/// `.translationTask` to translate — `TranslationSession` can only be
/// obtained inside a SwiftUI view (a platform constraint, not a design
/// choice this app can route around), so `SystemTranslationProvider` itself
/// can never call `TranslationSession.translate(_:)` directly.
public struct TranslationBridgeRequest: Identifiable, Sendable {
    public let id: UUID
    public let text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

/// Adapts macOS's on-device `Translation` framework (one-shot
/// request/response) to the same `feed`/`flush` shape a genuinely streaming
/// engine uses — see `TranslationProvider`'s doc. `feed(_:)` just
/// accumulates; `flush()` is the only point a translation actually happens.
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

    public init() {}

    public func loadModel() async throws {}
    public func unload() {}

    public func start(config: TranslationConfig) async throws {
        self.config = config
        buffer = ""
    }

    public func feed(_ text: String) {
        buffer += text
    }

    public func flush() {
        defer { onFlushBoundary?() }
        guard !buffer.isEmpty else { return }
        let text = buffer
        buffer = ""
        onBridgeRequest?(TranslationBridgeRequest(text: text))
    }

    public func stop() async {}

    /// Called by the bridging view once a request's `translate(_:)` resolves.
    public func receiveResult(_ text: String) {
        onCommit?(text)
    }

    public var currentSourceLanguageCode: String? { config?.sourceLanguageCode }
    public var currentTargetLanguageCode: String? { config?.targetLanguageCode ?? "" }
}
