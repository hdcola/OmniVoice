import Testing
@testable import OmniVoiceCore

struct StablePrefixTrackerTests {
    @Test func emitsOnlyPrefixConfirmedByTwoHypothesesAndAwayFromTheTail() {
        var tracker = StablePrefixTracker(holdback: 2)
        #expect(tracker.ingest("hello wor").appended == nil)
        let second = tracker.ingest("hello world")
        #expect(second.appended == "hello wor")
        #expect(second.tentative == "ld")
        let third = tracker.ingest("hello world again")
        #expect(third.appended == "ld")
        #expect(third.tentative == " again")
    }

    @Test func closeDeliversOnlyTheUnemittedTailAndResets() {
        var tracker = StablePrefixTracker(holdback: 2)
        _ = tracker.ingest("hello wor")
        _ = tracker.ingest("hello world")
        #expect(tracker.close(finalText: "hello world.") == "ld.")
        #expect(tracker.ingest("next").appended == nil)
    }

    @Test func rewriteInsideCommittedPrefixStopsEmitting() {
        var tracker = StablePrefixTracker(holdback: 2)
        _ = tracker.ingest("hello wor")
        _ = tracker.ingest("hello world")
        let rewritten = tracker.ingest("jello world!!")
        #expect(rewritten.appended == nil)
        #expect(tracker.close(finalText: "jello world!!") == "ld!!")
    }
}
