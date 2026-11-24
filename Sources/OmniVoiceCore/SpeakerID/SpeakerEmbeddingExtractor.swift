import CSherpaOnnx
import Foundation

/// Speaker embeddings via sherpa-onnx's C API (already linked for the
/// sherpa-onnx local engine). Not thread-safe: used only on `SpeakerTagger`'s queue.
final class SpeakerEmbeddingExtractor {
    private let handle: OpaquePointer

    init?(modelPath: String, threads: Int32 = 1) {
        var config = SherpaOnnxSpeakerEmbeddingExtractorConfig()
        let created: OpaquePointer? = modelPath.withCString { model in
            "cpu".withCString { provider in
                config.model = model
                config.provider = provider
                config.num_threads = threads
                config.debug = 0
                return SherpaOnnxCreateSpeakerEmbeddingExtractor(&config)
            }
        }
        guard let created else { return nil }
        handle = created
    }

    deinit { SherpaOnnxDestroySpeakerEmbeddingExtractor(handle) }

    /// 16 kHz mono audio → embedding; nil when the audio is too short.
    func embed(_ samples: [Float]) -> [Float]? {
        guard let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(handle) else { return nil }
        defer { SherpaOnnxDestroyOnlineStream(stream) }
        samples.withUnsafeBufferPointer {
            SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, $0.baseAddress, Int32($0.count))
        }
        SherpaOnnxOnlineStreamInputFinished(stream)
        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(handle, stream) != 0,
              let ptr = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(handle, stream)
        else { return nil }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(ptr) }
        let dim = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(handle))
        return Array(UnsafeBufferPointer(start: ptr, count: dim))
    }
}
