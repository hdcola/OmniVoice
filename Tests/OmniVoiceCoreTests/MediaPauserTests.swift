import XCTest
@testable import OmniVoiceCore

@MainActor
final class MediaPauserTests: XCTestCase {
    private final class Fake: MediaPlaybackProbe, MediaKeySender {
        var playing = false
        var presses = 0
        func isOtherAudioPlaying() -> Bool { playing }
        func sendPlayPause() {
            presses += 1
            playing.toggle()
        }
    }

    func testPausesAndResumesWhatItPaused() {
        let fake = Fake()
        fake.playing = true
        let pauser = MediaPauser(probe: fake, sender: fake)
        pauser.pauseIfPlaying()
        XCTAssertFalse(fake.playing)
        pauser.resumeIfWePaused()
        XCTAssertTrue(fake.playing)
        XCTAssertEqual(fake.presses, 2)
    }

    func testNeverPressesWhenNothingPlays() {
        let fake = Fake()
        let pauser = MediaPauser(probe: fake, sender: fake)
        pauser.pauseIfPlaying()
        pauser.resumeIfWePaused()
        XCTAssertEqual(fake.presses, 0)
    }

    func testDoesNotResumeWhenUserRestartedAudio() {
        let fake = Fake()
        fake.playing = true
        let pauser = MediaPauser(probe: fake, sender: fake)
        pauser.pauseIfPlaying()
        fake.playing = true // the user hit play themselves
        pauser.resumeIfWePaused()
        XCTAssertEqual(fake.presses, 1)
    }

    func testSecondPauseIsIgnoredAndResumeHappensOnce() {
        let fake = Fake()
        fake.playing = true
        let pauser = MediaPauser(probe: fake, sender: fake)
        pauser.pauseIfPlaying()
        pauser.pauseIfPlaying()
        pauser.resumeIfWePaused()
        pauser.resumeIfWePaused()
        XCTAssertEqual(fake.presses, 2)
    }
}
