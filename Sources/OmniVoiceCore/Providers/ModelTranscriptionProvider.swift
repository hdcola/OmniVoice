import Foundation

/// R2T2 in-process model ASR engine — wraps `InProcessTranscriber` (audio.cpp's
/// C ABI) to conform to `TranscriptionProvider`. Ported from
/// `../mac-poc-hybrid`'s validated `AppModel` wiring; see
/// `InProcessTranscriber`'s own doc for the streaming/thread-safety design
/// this delegates to unchanged.
public final class ModelTranscriptionProvider: TranscriptionProvider {
    public var onEvent: ((TranscriptionEvent) -> Void)?

    // `nonisolated(unsafe)`: `ModelTranscriptionProvider` is inferred
    // `@MainActor` (via `TranscriptionProvider`), but `push`/
    // `notifyUtteranceBoundary` are `nonisolated` and must reach
    // `transcriber` from whatever background audio/VAD queue calls them —
    // safe here because `InProcessTranscriber` is itself internally
    // thread-safe (one serial queue guards all its state, see its own doc),
    // the same justification `SystemTranscriptionProvider`'s
    // `nonisolated(unsafe)` fields document.
    private nonisolated(unsafe) let transcriber = InProcessTranscriber()
    /// Resolved weights path, if the caller (`RecordingSession.makeTranscriptionProvider`)
    /// already knows one — e.g. a downloaded model cache location. `nil`
    /// falls back to `InProcessTranscriber.resolveModelPath`'s env-var/local-
    /// `models/`-dir convention. Passed at construction, not via
    /// `start(config:)`, because `loadModel()` (where the path is actually
    /// read) runs *before* `start(config:)` in `RecordingSession.start()`.
    private let modelPath: URL?

    public init(modelPath: URL? = nil) {
        self.modelPath = modelPath
        transcriber.onDelta = { [weak self] delta in
            self?.onEvent?(.appended(delta))
        }
        transcriber.onFinalTail = { [weak self] tail in
            self?.onEvent?(.segmentClosed(finalAppend: tail))
        }
    }

    public func loadModel() async throws {
        try await transcriber.loadModel(modelPath: modelPath)
    }

    public func unload() {
        transcriber.unload()
    }

    public func start(config: TranscriptionConfig) async throws {
        transcriber.tuning.recognitionLanguage = ModelLanguageMapping.recognitionLanguage(forCode: config.languageCode)
        try transcriber.startStream()
    }

    public nonisolated func push(samples: [Float]) {
        transcriber.push(samples: samples)
    }

    public nonisolated func notifyUtteranceBoundary() {
        transcriber.rotateStream()
    }

    public func stop() async {
        // Ends the stream but deliberately leaves the model loaded — an
        // earlier version of this also called `transcriber.unload()` here,
        // which meant every "停止" silently freed R2T2's weights, forcing
        // the *next* "开始" to reload them from scratch (a multi-second
        // stall) even though nothing asked for that. `RecordingSession` now
        // owns the model's loaded lifetime independently of any one
        // recording's start/stop — see its `isModelLoaded` doc — and calls
        // `unload()` itself when that's actually warranted (an engine
        // switch, or quitting).
        transcriber.finishStream()
    }
}
