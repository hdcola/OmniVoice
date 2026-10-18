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
        #expect(rewritten.tentative == "jello world!!")
        #expect(tracker.close(finalText: "jello world!!") == "jello world!!")
    }

    @Test func divergenceMidWordBacksUpToTheWordStart() {
        var tracker = StablePrefixTracker(holdback: 0)
        _ = tracker.ingest("I think")
        _ = tracker.ingest("I think")
        #expect(tracker.close(finalText: "I thought that is true") == " thought that is true")
    }

    @Test func divergenceInChineseKeepsEverythingPastTheCommonPrefix() {
        var tracker = StablePrefixTracker(holdback: 0)
        _ = tracker.ingest("我们应该")
        _ = tracker.ingest("我们应该")
        #expect(tracker.close(finalText: "我们必须去做") == "必须去做")
    }

    @Test func divergedIngestKeepsTheTentativeVisible() {
        var tracker = StablePrefixTracker(holdback: 0)
        _ = tracker.ingest("I think")
        _ = tracker.ingest("I think")
        let diverged = tracker.ingest("I thought that")
        #expect(diverged.appended == nil)
        #expect(diverged.tentative == " thought that")
    }
}
