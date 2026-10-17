import CSherpaOnnx
import Foundation

enum SherpaTranscriberError: LocalizedError {
    case modelMissing(String)
    case createFailed
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .modelMissing(let path):
            return String(localized: "Model weights not found: \(path)")
        case .createFailed:
            return String(localized: "The recognition engine could not load the model")
        case .notLoaded:
            return String(localized: "The model is not loaded yet")
        }
    }
}

/// How a streaming model package is wired into sherpa's config.
private enum ModelLayout {
    case transducer(String, String, String)
    case paraformer(String, String)
    case zipformer2Ctc(String)
}

/// Streaming ASR (Zipformer transducer or CTC, Paraformer) in-process
/// via sherpa-onnx's C API. Unlike `InProcessTranscriber` (R2T2, append-only
/// deltas), sherpa reports the *whole current utterance* on every decode, so
/// this surfaces `onPartial` (full-replace hypothesis) and `onSegmentFinal`
/// (sherpa's own endpoint fired, or the stream was finished) — never deltas.
///
/// Thread-safety: same contract as `InProcessTranscriber` — one serial
/// `queue` guards every handle, since `push` arrives on the audio queue
/// while `start`/`finish` come from the main actor.
final class SherpaOnnxTranscriber: @unchecked Sendable {
    var onPartial: ((String) -> Void)?
    var onSegmentFinal: ((String) -> Void)?

    private let queue = DispatchQueue(label: "org.hdcola.omnivoice.inprocess.sherpa")
    private var recognizer: OpaquePointer?
    private var stream: OpaquePointer?
    private var lastPartial = ""
    private let sampleRate = 16_000

    /// `modelDir` holds one streaming model package, whose kind is read from
    /// its files: `encoder`/`decoder`/`joiner` `.onnx` is a transducer
    /// (Zipformer), `encoder`/`decoder` alone a Paraformer, a single `model*.onnx`
    /// a Zipformer2 CTC; all with `tokens.txt`. int8 files win when both
    /// precisions exist.
    func loadModel(modelDir: URL) throws {
        try queue.sync {
            guard recognizer == nil else { return }
            let files = try FileManager.default.contentsOfDirectory(atPath: modelDir.path)
            func pick(_ prefix: String) -> String? {
                let hits = files.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".onnx") }.sorted()
                return (hits.first { $0.contains("int8") } ?? hits.first).map { modelDir.appendingPathComponent($0).path }
            }
            let tokens = modelDir.appendingPathComponent("tokens.txt").path
            guard FileManager.default.fileExists(atPath: tokens) else {
                throw SherpaTranscriberError.modelMissing(modelDir.path)
            }
            let layout: ModelLayout
            if let encoder = pick("encoder"), let decoder = pick("decoder") {
                layout = pick("joiner").map { .transducer(encoder, decoder, $0) } ?? .paraformer(encoder, decoder)
            } else if let model = pick("model") {
                layout = .zipformer2Ctc(model)
            } else {
                throw SherpaTranscriberError.modelMissing(modelDir.path)
            }

            // The C config holds borrowed pointers, so keep the strdup'd
            // strings alive until the recognizer has copied what it needs.
            var owned: [UnsafeMutablePointer<CChar>] = []
            func cstr(_ s: String) -> UnsafePointer<CChar> {
                let p = strdup(s)!
                owned.append(p)
                return UnsafePointer(p)
            }
            defer { owned.forEach { free($0) } }

            var config = SherpaOnnxOnlineRecognizerConfig()
            config.feat_config.sample_rate = Int32(sampleRate)
            config.feat_config.feature_dim = 80
            switch layout {
            case .transducer(let encoder, let decoder, let joiner):
                config.model_config.transducer.encoder = cstr(encoder)
                config.model_config.transducer.decoder = cstr(decoder)
                config.model_config.transducer.joiner = cstr(joiner)
            case .paraformer(let encoder, let decoder):
                config.model_config.paraformer.encoder = cstr(encoder)
                config.model_config.paraformer.decoder = cstr(decoder)
            case .zipformer2Ctc(let model):
                config.model_config.zipformer2_ctc.model = cstr(model)
            }
            config.model_config.tokens = cstr(tokens)
            config.model_config.num_threads = 2
            config.model_config.provider = cstr("cpu")
            config.decoding_method = cstr("greedy_search")
            config.enable_endpoint = 1
            config.rule1_min_trailing_silence = 2.4
            config.rule2_min_trailing_silence = 1.2
            config.rule3_min_utterance_length = 20

            guard let created = SherpaOnnxCreateOnlineRecognizer(&config) else {
                throw SherpaTranscriberError.createFailed
            }
            recognizer = created
        }
    }

    func unload() {
        queue.sync {
            destroyStreamLocked()
            if let recognizer { SherpaOnnxDestroyOnlineRecognizer(recognizer) }
            recognizer = nil
        }
    }

    func startStream() throws {
        try queue.sync {
            guard let recognizer else { throw SherpaTranscriberError.notLoaded }
            destroyStreamLocked()
            stream = SherpaOnnxCreateOnlineStream(recognizer)
            lastPartial = ""
        }
    }

    func push(samples: [Float]) {
        queue.sync {
            guard let recognizer, let stream, !samples.isEmpty else { return }
            samples.withUnsafeBufferPointer {
                SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(sampleRate), $0.baseAddress, Int32($0.count))
            }
            decodeLocked(recognizer: recognizer, stream: stream)
            if SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream) != 0 {
                closeSegmentLocked(recognizer: recognizer, stream: stream)
                SherpaOnnxOnlineStreamReset(recognizer, stream)
            }
        }
    }

    /// Flushes the trailing audio (the model needs a little right-padding to
    /// emit its last tokens), reports whatever is left as a final segment and
    /// frees the stream. The recognizer stays loaded.
    func finishStream() {
        queue.sync {
            guard let recognizer, let stream else { return }
            let tail = [Float](repeating: 0, count: sampleRate * 4 / 10)
            tail.withUnsafeBufferPointer {
                SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(sampleRate), $0.baseAddress, Int32($0.count))
            }
            SherpaOnnxOnlineStreamInputFinished(stream)
            decodeLocked(recognizer: recognizer, stream: stream)
            closeSegmentLocked(recognizer: recognizer, stream: stream)
            destroyStreamLocked()
        }
    }

    // MARK: - queue-confined helpers

    private func decodeLocked(recognizer: OpaquePointer, stream: OpaquePointer) {
        while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 {
            SherpaOnnxDecodeOnlineStream(recognizer, stream)
        }
        let text = currentTextLocked(recognizer: recognizer, stream: stream)
        if text != lastPartial, !text.isEmpty {
            lastPartial = text
            onPartial?(text)
        }
    }

    private func closeSegmentLocked(recognizer: OpaquePointer, stream: OpaquePointer) {
        let text = currentTextLocked(recognizer: recognizer, stream: stream)
        lastPartial = ""
        if !text.isEmpty { onSegmentFinal?(text) }
    }

    private func currentTextLocked(recognizer: OpaquePointer, stream: OpaquePointer) -> String {
        guard let result = SherpaOnnxGetOnlineStreamResult(recognizer, stream) else { return "" }
        defer { SherpaOnnxDestroyOnlineRecognizerResult(result) }
        guard let raw = result.pointee.text.map({ String(cString: $0) }) else { return "" }
        // Some models emit their unknown-token literally.
        return raw.replacingOccurrences(of: "<unk>", with: "")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private func destroyStreamLocked() {
        if let stream { SherpaOnnxDestroyOnlineStream(stream) }
        stream = nil
    }
}
