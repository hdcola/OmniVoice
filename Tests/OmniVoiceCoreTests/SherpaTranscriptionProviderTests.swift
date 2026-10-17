import AVFoundation
import Foundation
import Testing
@testable import OmniVoiceCore

/// Smoke test for `SherpaTranscriptionProvider` against real streaming
/// models. The weights are gitignored and absent in CI, so each case runs
/// only when its model package exists in `models/sherpa-<variant id>/` (the
/// layout `Scripts/` and the download manager don't produce — fetch the
/// files listed in `ProviderCatalog` by hand) next to
/// `models/sherpa-test-wavs/0.wav`, a Chinese + English clip.
struct SherpaTranscriptionProviderTests {
    private static let modelsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("models")

    private static func modelDir(_ variantID: String) -> URL? {
        let dir = modelsRoot.appendingPathComponent("sherpa-\(variantID)")
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("tokens.txt").path) ? dir : nil
    }

    private static let wav = modelsRoot.appendingPathComponent("sherpa-test-wavs/0.wav")

    /// Variant IDs with their model package on disk (and the test clip).
    static let availableVariantIDs: [String] =
        FileManager.default.fileExists(atPath: wav.path)
            ? ProviderCatalog.modelVariants(forEngineID: "model.sherpa").map(\.id).filter { modelDir($0) != nil }
            : []

    private static func samples(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    @Test(.enabled(if: !SherpaTranscriptionProviderTests.availableVariantIDs.isEmpty),
          arguments: SherpaTranscriptionProviderTests.availableVariantIDs)
    @MainActor
    func streamsPartialsThenClosesTheSegment(variantID: String) async throws {
        let dir = try #require(Self.modelDir(variantID))
        let audio = try Self.samples(of: Self.wav)

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
        print("sherpa[\(variantID)] partials:", partials.count, "finals:", finals)
        #expect(!partials.isEmpty)
        #expect(!finals.isEmpty)
        #expect(!events.contains { if case .appended = $0 { true } else { false } })
    }
}
