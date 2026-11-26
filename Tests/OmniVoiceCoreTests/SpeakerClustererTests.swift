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

    @Test func dominantVoiceDropsMinorityVoice() {
        // 30 s from one person with 4 s from somebody else mixed in: keep the former.
        let a1 = SpeakerSample(embedding: [1, 0, 0], seconds: 20)
        let a2 = SpeakerSample(embedding: [0.9, 0.1, 0], seconds: 10)
        let b = SpeakerSample(embedding: [0, 1, 0], seconds: 4)
        let main = SpeakerVoice.dominant([b, a1, a2], sameVoice: 0.45)
        #expect(main.included.sorted() == [1, 2])
        #expect(main.embedding[0] > 0.99)
    }

    @Test func clustererKeepsPerRowSamples() {
        var c = SpeakerClusterer(threshold: 0.6)
        c.seed([0, 0, 1])
        _ = c.assign([1, 0, 0], seconds: 3)
        _ = c.assign([0.95, 0.05, 0], seconds: 2)
        #expect(c.samples(at: 0).isEmpty)
        #expect(c.samples(at: 1).map(\.seconds) == [3, 2])
    }

    @Test func issuesFindMixedAndSimilarProfiles() {
        let nick = SpeakerProfile(id: UUID(), name: "Nick", embedding: [1, 0, 0], updatedAt: .now, samples: [
            SpeakerSample(embedding: [1, 0, 0], seconds: 20),
            SpeakerSample(embedding: [0.98, 0.2, 0], seconds: 15),
            SpeakerSample(embedding: [0, 0, 1], seconds: 6),
        ])
        let seb = SpeakerProfile(id: UUID(), name: "Seb", embedding: [0.9, 0.436, 0], updatedAt: .now)
        let madi = SpeakerProfile(id: UUID(), name: "Madi", embedding: [0, 1, 0], updatedAt: .now)
        let issues = SpeakerProfileIssue.find(in: [nick, seb, madi], threshold: 0.6)
        #expect(issues.contains { if case let .mixed(id, s, _) = $0.kind { return id == nick.id && s == [2] }; return false })
        #expect(issues.contains { if case let .similar(a, b, _, same) = $0.kind { return a == nick.id && b == seb.id && same }; return false })
        var nick2 = nick
        nick2.distinctFrom = [seb.id]
        #expect(!SpeakerProfileIssue.find(in: [nick2, seb], threshold: 0.6).contains { if case .similar = $0.kind { return true }; return false })
    }

    @Test func voicesSavedBeforeSamplesStillLoad() throws {
        let json = #"[{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","name":"Alex","embedding":[0.6,0.8],"updatedAt":0}]"#
        let p = try JSONDecoder().decode([SpeakerProfile].self, from: Data(json.utf8))
        #expect(p.first?.allSamples.count == 1)
        #expect(p.first?.samples == nil)
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
