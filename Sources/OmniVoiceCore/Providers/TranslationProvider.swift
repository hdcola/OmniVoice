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

    public init(sourceLanguageCode: String? = nil, targetLanguageCode: String, modelPath: URL? = nil) {
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
        self.modelPath = modelPath
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

    /// Appends new source text to translate. Safe to call at any point after
    /// `start(config:)`.
    func feed(_ text: String)

    /// Forces whatever's buffered to be translated now (or, for a one-shot
    /// engine, translates the whole accumulated buffer), then fires
    /// `onFlushBoundary`.
    func flush()

    func stop() async
}
