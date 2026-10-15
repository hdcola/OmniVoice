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

    /// The resume is slow to be heard when the next dictation starts: no
    /// blind press, then a pause once the music turns up.
    func testLateResumeIsPausedWhenHeard() {
        let fake = Fake()
        fake.playing = true
        let pauser = makePauser(fake)
        pauser.pauseIfPlaying()
        time = 5
        fake.stale = nil
        pauser.resumeIfWePaused() // music coming back, probe still says silent
        time = 5.3
        pauser.pauseIfPlaying()
        XCTAssertEqual(fake.presses, 2) // nothing pressed blindly
        time = 5.6
        XCTAssertTrue(pauser.poll()) // still silent: keep waiting
        fake.stale = nil // the music is heard now
        time = 7
        XCTAssertFalse(pauser.poll())
        XCTAssertFalse(fake.playing)
        XCTAssertEqual(fake.presses, 3)
        time = 10
        fake.stale = nil
        pauser.resumeIfWePaused()
        XCTAssertTrue(fake.playing)
        XCTAssertEqual(fake.presses, 4)
    }

    /// The dictation ended before the late music showed up: leave it be.
    func testLateResumeAfterShortDictationIsLeftAlone() {
        let fake = Fake()
        fake.playing = true
        let pauser = makePauser(fake)
        pauser.pauseIfPlaying()
        time = 5
        fake.stale = nil
        pauser.resumeIfWePaused()
        time = 5.3
        pauser.pauseIfPlaying()
        pauser.resumeIfWePaused()
        fake.stale = nil
        time = 7
        XCTAssertFalse(pauser.poll())
        XCTAssertEqual(fake.presses, 2)
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

    /// Music already audible during the pending window: pause at once.
    func testAudibleLateResumePausesImmediately() {
        let fake = Fake()
        fake.playing = true
        let pauser = makePauser(fake)
        pauser.pauseIfPlaying()
        time = 5
        fake.stale = nil
        pauser.resumeIfWePaused()
        time = 8 // past the settle window, music is back
        fake.stale = nil
        pauser.pauseIfPlaying()
        XCTAssertFalse(fake.playing)
        XCTAssertEqual(fake.presses, 3)
    }
}
