import Foundation

/// T3PO in-process model translation engine — wraps `InProcessTranslator`
/// (llama.cpp's C ABI) to conform to `TranslationProvider`. Ported from
/// `../mac-poc-hybrid`'s validated `AppModel` wiring; see
/// `InProcessTranslator`'s own doc for the streaming WAIT/TRANS design this
/// delegates to unchanged.
public final class ModelTranslationProvider: TranslationProvider {
    public var onCommit: ((String) -> Void)?
    public var onPreview: ((String) -> Void)?
    public var onFlushBoundary: (() -> Void)?

    private let translator = InProcessTranslator()
    /// See `ModelTranscriptionProvider.modelPath`'s doc for why this is a
    /// constructor parameter rather than threaded through `start(config:)`.
    private let modelPath: URL?

    public init(modelPath: URL? = nil) {
        self.modelPath = modelPath
        translator.onPartialTranslation = { [weak self] text in
            self?.onCommit?(text)
        }
        translator.onPreviewTranslation = { [weak self] text in
            self?.onPreview?(text)
        }
        translator.onFlushBoundary = { [weak self] in
            self?.onFlushBoundary?()
        }
    }

    public func loadModel() async throws {
        try translator.loadModel(modelPath: modelPath)
    }

    public func unload() {
        translator.unload()
    }

    public func start(config: TranslationConfig) async throws {
        // `config.sourceLanguageCode` is deliberately unused — T3PO's prompt
        // asks for "live speech" and relies on the model to recognize the
        // source language itself (see `InProcessTranslator.systemPrompt`'s
        // doc), same as its reference engine.
        translator.setTargetLanguage(ModelLanguageMapping.t3poTargetLanguage(forCode: config.targetLanguageCode))
    }

    public func feed(_ text: String) {
        translator.feed(sourceDelta: text)
    }

    public func flush() {
        translator.flush()
    }

    public func stop() async {
        translator.unload()
    }
}
