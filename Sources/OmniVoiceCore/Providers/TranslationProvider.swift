import Foundation

/// Session-scope configuration for a `TranslationProvider`.
public struct TranslationConfig: Sendable {
    /// Source language, when known — leaving this nil and relying on a
    /// provider's own auto-detection is deliberately avoided upstream where
    /// possible (see `SystemTranslationProvider`'s doc: on-device
    /// `Translation` can pop an unanswerable system prompt on ambiguous
    /// short text when `source` is left unset).
    public var sourceLanguageCode: String?
    public var targetLanguageCode: String
    /// Resolved path to a model weights file, only meaningful for `.model`
    /// providers.
    public var modelPath: URL?
    /// See `TranslationCommitEagerness`'s doc — only meaningful for a
    /// streaming `.model`-kind provider (T3PO); ignored by a one-shot one.
    public var commitEagerness: TranslationCommitEagerness
    /// User-configurable character count that justifies a **one-shot**
    /// engine (`HYMT15Translator`, `SystemTranslationProvider`) translating
    /// early, within a still-open ASR segment, rather than waiting for the
    /// segment's real boundary — see `SystemTranslationProvider.feed(_:)`'s
    /// doc for the full reasoning (a long, pause-free utterance shouldn't
    /// leave the user waiting for a translation, or waiting on a large block
    /// of text all at once, until the speaker finally stops). Ignored by
    /// T3PO, which reads `commitEagerness` instead. A plain, directly
    /// user-configurable number (not another `TranslationCommitEagerness`
    /// case) since it has no probabilistic-bias equivalent to keep in the
    /// same small enum vocabulary as `commitEagerness` — this app's own
    /// small vocabulary is for concepts every engine can express in its own
    /// terms, and a one-shot engine's "how long is too long" genuinely is
    /// just a character count.
    public var earlyTranslateThreshold: Int

    public init(
        sourceLanguageCode: String? = nil, targetLanguageCode: String, modelPath: URL? = nil,
        commitEagerness: TranslationCommitEagerness = .balanced, earlyTranslateThreshold: Int = 150
    ) {
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
        self.modelPath = modelPath
        self.commitEagerness = commitEagerness
        self.earlyTranslateThreshold = earlyTranslateThreshold
    }
}

/// Drives translation for one recording. Deliberately the **same** interface
/// for a genuinely streaming engine (T3PO's WAIT/TRANS policy) and a
/// one-shot request/response engine (`TranslationSession.translate(_:)`):
/// callers always just `feed(_:)` new source text as it becomes available and
/// `flush()` at a segment boundary, never branching on which kind of engine
/// is behind the protocol. A one-shot implementation satisfies this by
/// buffering everything `feed(_:)` gives it and only actually translating
/// (once) inside `flush()` — see `SystemTranslationProvider`.
///
/// `@MainActor`-isolated — see `TranscriptionProvider`'s doc for why.
@MainActor
public protocol TranslationProvider: AnyObject {
    /// Fires once per **committed** translation — append-only, never a
    /// revision of a previous commit.
    var onCommit: ((String) -> Void)? { get set }
    /// Fires with a live best-guess translation of whatever's currently
    /// buffered/uncommitted. Optional — a provider with no meaningful preview
    /// (e.g. a one-shot engine, which has nothing to guess with until it's
    /// asked) simply never calls this.
    var onPreview: ((String) -> Void)? { get set }
    /// Fires once per `flush()` call, whether or not that flush produced a
    /// commit — a boundary marker callers use to know "no more `onCommit`
    /// calls belong to text fed before this flush".
    var onFlushBoundary: (() -> Void)? { get set }

    /// Loads whatever backend/model this provider needs. A no-op for system
    /// providers.
    func loadModel() async throws
    func unload()

    /// Starts a fresh session — clears any buffered text/history from a
    /// previous recording.
    func start(config: TranslationConfig) async throws

    /// Retargets an already-running session to a new target language,
    /// without a full stop/start — for a provider that reads the target
    /// language on every request rather than baking it into a persistent
    /// session (a streaming `.model`-kind engine like T3PO), this is what
    /// lets `RecordingSession.targetLanguageCode` changing mid-recording
    /// actually apply to the *next* translation instead of silently
    /// continuing to translate into whatever language `start(config:)` set.
    /// The default implementation is a no-op, which is correct (not just a
    /// placeholder) for a provider with nothing to retarget here —
    /// `SystemTranslationProvider` already reads target language fresh from
    /// `RecordingSession` on every `.translationTask` rebuild instead (see
    /// `FloatingTranscriptView.rebuildConfiguration()`), so it has no
    /// persistent per-session target to update.
    func updateTargetLanguage(_ code: String)

    /// Same mid-session-retargeting reasoning as `updateTargetLanguage(_:)`'s
    /// doc, for `TranslationCommitEagerness` instead of target language — the
    /// default no-op is correct for a one-shot provider, which has nothing to
    /// retune here.
    func updateCommitEagerness(_ eagerness: TranslationCommitEagerness)

    /// Same mid-session reasoning as `updateTargetLanguage(_:)`'s doc, for
    /// `TranslationConfig.earlyTranslateThreshold` instead — the default
    /// no-op is correct for T3PO, which has nothing to retune here (it reads
    /// `commitEagerness` instead).
    func updateEarlyTranslateThreshold(_ characters: Int)

    /// Appends new source text to translate. Safe to call at any point after
    /// `start(config:)`.
    func feed(_ text: String)

    /// Forces whatever's buffered to be translated now (or, for a one-shot
    /// engine, translates the whole accumulated buffer), then fires
    /// `onFlushBoundary`.
    func flush()

    func stop() async
}

extension TranslationProvider {
    public func updateTargetLanguage(_ code: String) {}
    public func updateCommitEagerness(_ eagerness: TranslationCommitEagerness) {}
    public func updateEarlyTranslateThreshold(_ characters: Int) {}
}
