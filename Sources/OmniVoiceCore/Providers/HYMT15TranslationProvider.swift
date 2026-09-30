import Foundation

/// HY-MT1.5 in-process model translation engine — wraps `HYMT15Translator`
/// to conform to `TranslationProvider`. See `HYMT15Translator`'s class doc
/// for why, unlike `ModelTranslationProvider` (T3PO), this engine never
/// fires `onPreview` — it's a one-shot model, translated at `flush()` (a
/// real ASR segment boundary) or, for a long enough buffered utterance,
/// early — see `TranslationConfig.earlyTranslateThreshold`'s doc.
///
/// The translator itself comes from `HYMT15ModelPool` in `loadModel()`
/// rather than being owned outright, so a selection translation panel using
/// the same weights at the same time shares this copy instead of loading a
/// second one.
public final class HYMT15TranslationProvider: TranslationProvider {
    public var onCommit: ((String) -> Void)?
    public var onPreview: ((String) -> Void)?
    public var onFlushBoundary: (() -> Void)?

    /// nil until `loadModel()` has acquired it, and again after `unload()`.
    private var translator: HYMT15Translator?
    private var acquiring: Task<HYMT15Translator, Error>?
    private var releaseWhenAcquired = false
    /// See `ModelTranscriptionProvider.modelPath`'s doc for why this is a
    /// constructor parameter rather than threaded through `start(config:)`.
    private let modelPath: URL?
    /// Remembered so settings changed before the model is acquired still
    /// apply once it is.
    private var targetLanguage: HYMT15TargetLanguage = .chinese
    private var earlyTranslateThreshold = 150

    public init(modelPath: URL? = nil) {
        self.modelPath = modelPath
    }

    public func loadModel() async throws {
        guard translator == nil else { return }
        // Overlapping calls (a preload racing `start()`) share one pool
        // acquisition — two would take two holds that `unload()` only
        // releases one of, leaving the weights loaded past quit.
        if let acquiring {
            _ = try await acquiring.value
            return
        }
        // The task itself installs `translator` (or gives the hold back),
        // not the caller after its `await`: every overlapping caller
        // resumes from the same `task.value`, in no guaranteed order, and
        // one resuming before the installer would otherwise return with
        // `translator` still nil — its `feed`s silently dropped.
        let modelPath = modelPath
        let task = Task { [weak self] () throws -> HYMT15Translator in
            defer { self?.acquiring = nil }
            let acquired = try await HYMT15ModelPool.shared.acquire(modelURL: modelPath)
            guard let self, !self.releaseWhenAcquired else {
                // `unload()` ran (or this provider went away) while the
                // weights were still loading.
                self?.releaseWhenAcquired = false
                HYMT15ModelPool.shared.release(acquired)
                return acquired
            }
            acquired.setCallbacks(
                onCommit: { [weak self] text in self?.onCommit?(text) },
                onFlushBoundary: { [weak self] in self?.onFlushBoundary?() }
            )
            acquired.setTargetLanguage(self.targetLanguage)
            acquired.setEarlyTranslateThreshold(self.earlyTranslateThreshold)
            self.translator = acquired
            return acquired
        }
        acquiring = task
        _ = try await task.value
    }

    public func unload() {
        guard let translator else {
            if acquiring != nil { releaseWhenAcquired = true }
            return
        }
        self.translator = nil
        // The pool may keep this instance alive for the selection panel —
        // don't leave this recording's buffered text/context behind in it.
        translator.resetSession()
        translator.setCallbacks(onCommit: nil, onFlushBoundary: nil)
        HYMT15ModelPool.shared.release(translator)
    }

    public func start(config: TranslationConfig) async throws {
        // `config.sourceLanguageCode` is deliberately unused — same
        // reasoning as `ModelTranslationProvider.start(config:)`'s doc:
        // HY-MT1.5's prompt only names the target language.
        updateTargetLanguage(config.targetLanguageCode)
        updateEarlyTranslateThreshold(config.earlyTranslateThreshold)
    }

    public func updateTargetLanguage(_ code: String) {
        targetLanguage = ModelLanguageMapping.hyMT15TargetLanguage(forCode: code)
        translator?.setTargetLanguage(targetLanguage)
    }

    public func updateEarlyTranslateThreshold(_ characters: Int) {
        earlyTranslateThreshold = characters
        translator?.setEarlyTranslateThreshold(characters)
    }

    public func feed(_ text: String) {
        translator?.feed(sourceDelta: text)
    }

    public func flush() {
        if let translator {
            translator.flush()
        } else {
            // Same always-fires boundary contract `HYMT15Translator.flush()`
            // keeps, even with nothing loaded to translate.
            onFlushBoundary?()
        }
    }

    public func stop() async {
        // Ends this recording's buffered state but leaves the model loaded
        // — same reasoning as `ModelTranslationProvider.stop()`'s doc.
        translator?.resetSession()
    }
}
