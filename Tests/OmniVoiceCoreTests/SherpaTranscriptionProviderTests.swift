import AVFoundation
import Foundation
import Testing
@testable import OmniVoiceCore

/// Smoke test for `SherpaTranscriptionProvider` against a real streaming
/// Zipformer model. The weights are gitignored and absent in CI, so this
/// runs only when `models/sherpa-zipformer-bilingual-zh-en` exists (or
/// `SHERPA_MODEL_DIR` points at another unpacked model with a
/// `test_wavs/0.wav` next to it).
struct SherpaTranscriptionProviderTests {
    private static let modelDir: URL? = {
        let path = ProcessInfo.processInfo.environment["SHERPA_MODEL_DIR"]
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("models/sherpa-zipformer-bilingual-zh-en").path
        return FileManager.default.fileExists(atPath: path + "/tokens.txt") ? URL(fileURLWithPath: path) : nil
    }()

    private static func samples(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    @Test(.enabled(if: SherpaTranscriptionProviderTests.modelDir != nil))
    @MainActor
    func streamsPartialsThenClosesTheSegment() async throws {
        let dir = try #require(Self.modelDir)
        let audio = try Self.samples(of: dir.appendingPathComponent("test_wavs/0.wav"))

        let provider = SherpaTranscriptionProvider(modelDir: dir)
        var events: [TranscriptionEvent] = []
        provider.onEvent = { events.append($0) }

        try await provider.loadModel()
        try await provider.start(config: TranscriptionConfig())
        // 100 ms chunks, like the live capture path.
        for start in stride(from: 0, to: audio.count, by: 1_600) {
            provider.push(samples: Array(audio[start..<min(start + 1_600, audio.count)]))
        }
        await provider.stop()
        provider.unload()

        let partials = events.compactMap { event -> String? in
            if case .revised(let text) = event { return text } else { return nil }
        }
        let finals = events.compactMap { event -> String? in
            if case .segmentClosed(let text) = event { return text } else { return nil }
        }
        print("sherpa partials:", partials.count, "last:", partials.last ?? "-")
        print("sherpa finals:", finals)
        #expect(!partials.isEmpty)
        #expect(!finals.isEmpty)
        #expect(!events.contains { if case .appended = $0 { true } else { false } })
    }
}
