import Testing
@testable import OmniVoiceCore

struct InputLevelTests {
    @Test func peakIsZeroForSilence() {
        #expect(InputLevel.peak([0, 0, 0]) == 0)
        #expect(InputLevel.peak([]) == 0)
    }

    @Test func peakIsFullAtZeroDBFSAndBelowTheFloorIsZero() {
        #expect(InputLevel.peak([0.1, -1]) == 1)
        // -60 dBFS is under the -45 dBFS floor.
        #expect(InputLevel.peak([0.001]) == 0)
    }

    @Test func peakRisesWithLoudness() {
        #expect(InputLevel.peak([0.05]) < InputLevel.peak([0.5]))
    }

    @Test func smoothingRisesAtOnceAndFallsGradually() {
        #expect(InputLevel.smoothed(current: 0.2, new: 0.8) == 0.8)
        let fallen = InputLevel.smoothed(current: 0.8, new: 0)
        #expect(fallen > 0 && fallen < 0.8)
    }
}
