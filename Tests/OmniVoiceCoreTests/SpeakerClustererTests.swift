import Foundation
import Testing
@testable import OmniVoiceCore

/// Speaker identification: clustering and remembered-voice storage.
@Suite("SpeakerClusterer")
struct SpeakerClustererTests {
    @Test func groupsSimilarVoicesAndSplitsDifferentOnes() {
        var c = SpeakerClusterer(threshold: 0.6)
        #expect(c.assign([1, 0, 0]) == 0)
        #expect(c.assign([0.95, 0.05, 0]) == 0)
        #expect(c.assign([0, 1, 0]) == 1)
        #expect(c.assign([0, 0, 1]) == 2)
        #expect(c.assign([0.1, 0.9, 0]) == 1)
        #expect(c.speakerCount == 3)
    }

    @Test func resetStartsNumberingAgain() {
        var c = SpeakerClusterer()
        _ = c.assign([1, 0])
        _ = c.assign([0, 1])
        c.reset()
        #expect(c.assign([0, 1]) == 0)
    }

    @Test func capsSpeakerCount() {
        var c = SpeakerClusterer(threshold: 0.99, maxSpeakers: 2)
        _ = c.assign([1, 0, 0])
        _ = c.assign([0, 1, 0])
        #expect(c.assign([0, 0, 1]) < 2)
    }

    @Test func seededVoiceIsRecognizedFirst() {
        var c = SpeakerClusterer(threshold: 0.6)
        #expect(c.seed([0, 1, 0]) == 0)
        #expect(c.assign([1, 0, 0]) == 1)
        #expect(c.assign([0.05, 0.95, 0]) == 0)
        #expect(c.centroid(at: 0)?.count == 3)
        #expect(c.centroid(at: 5) == nil)
    }

    @Test func rememberedVoiceUsesLowerThreshold() {
        // ~0.5 similarity: below the 0.6 threshold but above the 0.45 one for remembered voices.
        var c = SpeakerClusterer(threshold: 0.6)
        #expect(abs(c.seedThreshold - 0.45) < 0.001)
        c.seed([1, 0, 0])
        #expect(c.assign([0.5, 0.866, 0]) == 0)
        #expect(c.lastBestSeedSimilarity.map { abs($0 - 0.5) < 0.01 } == true)
        #expect(c.assign([0, 0, 1]) == 1)
    }

    @Test func withoutSeedsNoSeedSimilarity() {
        var c = SpeakerClusterer(threshold: 0.6)
        _ = c.assign([1, 0])
        #expect(c.lastBestSeedSimilarity == nil)
    }

    @Test func profileStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SpeakerProfileStore(fileURL: url)
        #expect(store.load().isEmpty)
        let p = SpeakerProfile(id: UUID(), name: "Alex", embedding: [0.6, 0.8], updatedAt: .now)
        store.save([p])
        #expect(store.load().map(\.name) == ["Alex"])
    }

    @Test func letters() {
        #expect(SpeakerClusterer.letter(for: 0) == "A")
        #expect(SpeakerClusterer.letter(for: 25) == "Z")
        #expect(SpeakerClusterer.letter(for: 26) == "AA")
    }
}
