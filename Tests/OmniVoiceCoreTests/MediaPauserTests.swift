import XCTest
@testable import OmniVoiceCore

@MainActor
final class MediaPauserTests: XCTestCase {
    private final class Fake: MediaPlaybackProbe, MediaKeySender {
        var playing = false
        var presses = 0
        /// Audio output lags the key: while true, `playing` is what the
        /// probe reports instead of the real state.
        var stale: Bool?
        func isOtherAudioPlaying() -> Bool { stale ?? playing }
        func sendPlayPause() {
            presses += 1
            stale = playing // the output still shows the old state
            playing.toggle()
        }
    }

    private var time: TimeInterval = 0
    private func makePauser(_ fake: Fake) -> MediaPauser {
        MediaPauser(probe: fake, sender: fake, now: { [unowned self] in time })
    }

    func testPausesAndResumesWhatItPaused() {
        let fake = Fake()
        fake.playing = true
        let pauser = makePauser(fake)
        pauser.pauseIfPlaying()
        XCTAssertFalse(fake.playing)
        time = 5
        fake.stale = nil
        pauser.resumeIfWePaused()
        XCTAssertTrue(fake.playing)
        XCTAssertEqual(fake.presses, 2)
    }

    func testNeverPressesWhenNothingPlays() {
        let fake = Fake()
        let pauser = makePauser(fake)
        pauser.pauseIfPlaying()
        pauser.resumeIfWePaused()
        XCTAssertEqual(fake.presses, 0)
    }

    func testDoesNotResumeWhenUserRestartedAudio() {
        let fake = Fake()
        fake.playing = true
        let pauser = makePauser(fake)
        pauser.pauseIfPlaying()
        time = 5
        fake.stale = nil
        fake.playing = true // the user hit play themselves
        pauser.resumeIfWePaused()
        XCTAssertEqual(fake.presses, 1)
    }

    func testSecondPauseIsIgnoredAndResumeHappensOnce() {
        let fake = Fake()
        fake.playing = true
        let pauser = makePauser(fake)
        pauser.pauseIfPlaying()
        pauser.pauseIfPlaying()
        pauser.resumeIfWePaused()
        pauser.resumeIfWePaused()
        XCTAssertEqual(fake.presses, 2)
    }

    /// The resume hasn't reached the output yet when the next dictation starts.
    func testQuickSecondDictationPausesAgain() {
        let fake = Fake()
        fake.playing = true
        let pauser = makePauser(fake)
        pauser.pauseIfPlaying()
        time = 5
        fake.stale = nil
        pauser.resumeIfWePaused() // music coming back, probe still says silent
        time = 5.3
        XCTAssertFalse(fake.isOtherAudioPlaying())
        pauser.pauseIfPlaying()
        XCTAssertFalse(fake.playing)
        XCTAssertEqual(fake.presses, 3)
        time = 9
        fake.stale = nil
        pauser.resumeIfWePaused()
        XCTAssertTrue(fake.playing)
    }

    /// A very short dictation: the pause is still draining at the end.
    func testInstantFinishStillResumes() {
        let fake = Fake()
        fake.playing = true
        let pauser = makePauser(fake)
        pauser.pauseIfPlaying()
        time = 0.2
        XCTAssertTrue(fake.isOtherAudioPlaying()) // stale output
        pauser.resumeIfWePaused()
        XCTAssertTrue(fake.playing)
        XCTAssertEqual(fake.presses, 2)
    }
}
