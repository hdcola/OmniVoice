import Foundation

/// HY-MT1.5 in-process model translation engine — wraps `HYMT15Translator`
/// to conform to `TranslationProvider`. See `HYMT15Translator`'s class doc
/// for why, unlike `ModelTranslationProvider` (T3PO), this engine never
/// fires `onPreview` — it's a one-shot model, translated only at `flush()`.
public final class HYMT15TranslationProvider: TranslationProvider {
    public var onCommit: ((String) -> Void)?
    public var onPreview: ((String) -> Void)?
    public var onFlushBoundary: (() -> Void)?

    private let translator = HYMT15Translator()
    /// See `ModelTranscriptionProvider.modelPath`'s doc for why this is a
    /// constructor parameter rather than threaded through `start(config:)`.
    private let modelPath: URL?

    public init(modelPath: URL? = nil) {
        self.modelPath = modelPath
        translator.onCommit = { [weak self] text in
            self?.onCommit?(text)
        }
        translator.onFlushBoundary = { [weak self] in
            self?.onFlushBoundary?()
        }
    }

    public func loadModel() async throws {
        try await translator.loadModel(modelPath: modelPath)
    }

    public func unload() {
        translator.unload()
    }

    public func start(config: TranslationConfig) async throws {
        // `config.sourceLanguageCode` is deliberately unused — same
        // reasoning as `ModelTranslationProvider.start(config:)`'s doc:
        // HY-MT1.5's prompt only names the target language.
        translator.setTargetLanguage(ModelLanguageMapping.hyMT15TargetLanguage(forCode: config.targetLanguageCode))
    }

    public func updateTargetLanguage(_ code: String) {
        translator.setTargetLanguage(ModelLanguageMapping.hyMT15TargetLanguage(forCode: code))
    }

    public func feed(_ text: String) {
        translator.feed(sourceDelta: text)
    }

    public func flush() {
        translator.flush()
    }

    public func stop() async {
        // Ends this recording's buffered state but leaves the model loaded
        // — same reasoning as `ModelTranslationProvider.stop()`'s doc.
        translator.resetSession()
    }
}
