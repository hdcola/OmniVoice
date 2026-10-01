import XCTest

@testable import OmniVoiceCore

final class UtteranceSegmenterTests: XCTestCase {
    private let speech = [Float](repeating: 0.2, count: 1600)  // 0.1s, ~-14 dBFS
    private let quiet = [Float](repeating: 0.001, count: 1600)  // 0.1s, -60 dBFS

    private func boundaries(_ segmenter: UtteranceSegmenter, silentChunks: Int) -> Int {
        var count = 0
        segmenter.onUtteranceBoundary = { count += 1 }
        segmenter.submit(speech)
        for _ in 0..<silentChunks { segmenter.submit(quiet) }
        return count
    }

    func testDefaultsFireAfterSixTenthsOfASecond() {
        XCTAssertEqual(boundaries(UtteranceSegmenter(), silentChunks: 5), 0)
        XCTAssertEqual(boundaries(UtteranceSegmenter(), silentChunks: 6), 1)
    }

    func testLongerPauseThresholdDelaysBoundary() {
        let segmenter = UtteranceSegmenter()
        segmenter.update(silenceThresholdSeconds: 1.5, silenceRMSDBFS: -40)
        XCTAssertEqual(boundaries(segmenter, silentChunks: 10), 0)
    }

    func testLowerDBFSThresholdTreatsQuietAudioAsSpeech() {
        let segmenter = UtteranceSegmenter()
        segmenter.update(silenceThresholdSeconds: 0.6, silenceRMSDBFS: -70)
        XCTAssertEqual(boundaries(segmenter, silentChunks: 10), 0)
    }
}
