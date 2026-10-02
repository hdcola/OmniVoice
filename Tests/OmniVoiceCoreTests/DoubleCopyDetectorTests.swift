import Testing
@testable import OmniVoiceCore

@Suite("DoubleCopyDetector")
struct DoubleCopyDetectorTests {
    /// Feeds presses at `times` and returns whether each one completed a double
    /// (`#expect` can't call a mutating member inline).
    private func fires(_ times: [Double], interval: Double = 0.35) -> [Bool] {
        var detector = DoubleCopyDetector(interval: interval)
        return times.map { detector.registerCopy(at: $0) }
    }

    @Test("a single press never fires")
    func singlePress() {
        #expect(fires([0]) == [false])
    }

    @Test("two presses within the interval fire on the second")
    func quickDouble() {
        #expect(fires([10, 10.3]) == [false, true])
    }

    @Test("two presses further apart than the interval do not fire")
    func slowPair() {
        #expect(fires([10, 10.5]) == [false, false])
    }

    @Test("the later press of a slow pair starts the next pair")
    func slowPairThenQuick() {
        #expect(fires([10, 11, 11.2]) == [false, false, true])
    }

    @Test("a double consumes both presses, so a third quick press starts a new pair")
    func tripleDoesNotRefire() {
        #expect(fires([10, 10.2, 10.4, 10.6]) == [false, true, false, true])
    }

    @Test("a bounce under the minimum gap is ignored and the pair still completes")
    func bounce() {
        #expect(fires([10, 10.02, 10.2]) == [false, false, true])
    }

    @Test("reset forgets the previous press")
    func reset() {
        var detector = DoubleCopyDetector(interval: 0.35)
        _ = detector.registerCopy(at: 10)
        detector.reset()
        let afterReset = detector.registerCopy(at: 10.1)
        #expect(!afterReset)
    }

    @Test("a clock that goes backwards never fires")
    func backwardsClock() {
        #expect(fires([10, 9.9]) == [false, false])
    }
}
