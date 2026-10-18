import Foundation

/// sherpa-onnx streaming ASR engine (prototype) — wraps `SherpaOnnxTranscriber`
/// to conform to `TranscriptionProvider`.
///
/// Event mapping: sherpa re-reports the whole current utterance on every
/// decode. `StablePrefixTracker` turns the part of that hypothesis that has
/// stopped changing into `.appended` deltas (so translation can run while the
/// utterance is still going), the volatile remainder is `.revised`, and
/// `.segmentClosed` carries whatever was never appended when sherpa's own
/// endpoint detector fires or the recording stops.
/// `notifyUtteranceBoundary()` is deliberately ignored — the VAD hint is only
/// needed by engines without their own endpointing.
public final class SherpaTranscriptionProvider: TranscriptionProvider {
    public var onEvent: ((TranscriptionEvent) -> Void)?

    private let transcriber = SherpaOnnxTranscriber()
    private let modelDir: URL?
    private let trackerLock = NSLock()
    private var tracker = StablePrefixTracker()

    /// - Parameter modelDir: `nil` when no model is downloaded — `loadModel()`
    ///   then throws. Otherwise the directory of an unpacked
    ///   `sherpa-onnx-streaming-zipformer-*` model (encoder/decoder/joiner
    ///   `.onnx` + `tokens.txt`).
    public init(modelDir: URL? = nil) {
        self.modelDir = modelDir
        transcriber.onPartial = { [weak self] text in
            guard let self else { return }
            self.trackerLock.lock()
            let result = self.tracker.ingest(text)
            self.trackerLock.unlock()
            if let appended = result.appended { self.onEvent?(.appended(appended)) }
            self.onEvent?(.revised(result.tentative))
        }
        transcriber.onSegmentFinal = { [weak self] text in
            guard let self else { return }
            self.trackerLock.lock()
            let tail = self.tracker.close(finalText: text)
            self.trackerLock.unlock()
            self.onEvent?(.segmentClosed(finalAppend: tail))
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
        trackerLock.lock()
        tracker.reset()
        trackerLock.unlock()
        try transcriber.startStream()
    }

    public nonisolated func push(samples: [Float]) {
        transcriber.push(samples: samples)
    }

    public func stop() async {
        transcriber.finishStream()
    }
}
