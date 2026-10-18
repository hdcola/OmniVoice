import Foundation

/// sherpa-onnx streaming ASR engine (prototype) — wraps `SherpaOnnxTranscriber`
/// to conform to `TranscriptionProvider`.
///
/// Event mapping: sherpa re-reports the whole current utterance on every
/// decode, so partial results are `.revised` (display-only, never fed to
/// translation) and the whole text arrives via `.segmentClosed` when sherpa's
/// own endpoint detector fires or the recording stops. It never emits
/// `.appended`, so translation of this engine's output waits for segment end.
/// `notifyUtteranceBoundary()` is deliberately ignored — the VAD hint is only
/// needed by engines without their own endpointing.
public final class SherpaTranscriptionProvider: TranscriptionProvider {
    public var onEvent: ((TranscriptionEvent) -> Void)?

    private let transcriber = SherpaOnnxTranscriber()
    private let modelDir: URL?

    /// - Parameter modelDir: `nil` when no model is downloaded — `loadModel()`
    ///   then throws. Otherwise the directory of an unpacked
    ///   `sherpa-onnx-streaming-zipformer-*` model (encoder/decoder/joiner
    ///   `.onnx` + `tokens.txt`).
    public init(modelDir: URL? = nil) {
        self.modelDir = modelDir
        transcriber.onPartial = { [weak self] text in
            self?.onEvent?(.revised(text))
        }
        transcriber.onSegmentFinal = { [weak self] text in
            self?.onEvent?(.segmentClosed(finalAppend: text))
        }
    }

    public func loadModel() async throws {
        guard let modelDir else { throw SherpaTranscriberError.modelMissing("sherpa-onnx") }
        try transcriber.loadModel(modelDir: modelDir)
    }

    public func unload() {
        transcriber.unload()
    }

    public func start(config: TranscriptionConfig) async throws {
        // The bilingual model detects zh/en itself; `config.languageCode` has
        // nothing to select.
        try transcriber.startStream()
    }

    public nonisolated func push(samples: [Float]) {
        transcriber.push(samples: samples)
    }

    public func stop() async {
        transcriber.finishStream()
    }
}
