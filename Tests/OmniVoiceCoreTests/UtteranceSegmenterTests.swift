import Testing

@testable import OmniVoiceCore

struct UtteranceSegmenterTests {
    private let speech = [Float](repeating: 0.2, count: 1600)  // 0.1s, ~-14 dBFS
    private let quiet = [Float](repeating: 0.001, count: 1600)  // 0.1s, -60 dBFS

    private func boundaries(_ segmenter: UtteranceSegmenter, silentChunks: Int) -> Int {
        var count = 0
        segmenter.onUtteranceBoundary = { count += 1 }
        segmenter.submit(speech)
        for _ in 0..<silentChunks { segmenter.submit(quiet) }
        return count
    }

    @Test func defaultsFireAfterSixTenthsOfASecond() {
        #expect(boundaries(UtteranceSegmenter(), silentChunks: 5) == 0)
        #expect(boundaries(UtteranceSegmenter(), silentChunks: 6) == 1)
    }

    @Test func longerPauseThresholdDelaysBoundary() {
        let segmenter = UtteranceSegmenter()
        segmenter.update(silenceThresholdSeconds: 1.5, silenceRMSDBFS: -40)
        #expect(boundaries(segmenter, silentChunks: 14) == 0)
        #expect(boundaries(segmenter, silentChunks: 15) == 1)
    }

    @Test func updateMidStreamTakesEffectImmediately() {
        let segmenter = UtteranceSegmenter()
        var count = 0
        segmenter.onUtteranceBoundary = { count += 1 }
        segmenter.submit(speech)
        for _ in 0..<4 { segmenter.submit(quiet) }
        #expect(count == 0)
        segmenter.update(silenceThresholdSeconds: 0.5, silenceRMSDBFS: -40)
        segmenter.submit(quiet)
        #expect(count == 1)
    }

    @Test func lowerDBFSThresholdTreatsQuietAudioAsSpeech() {
        let segmenter = UtteranceSegmenter()
        segmenter.update(silenceThresholdSeconds: 0.6, silenceRMSDBFS: -70)
        #expect(boundaries(segmenter, silentChunks: 10) == 0)
    }
}
