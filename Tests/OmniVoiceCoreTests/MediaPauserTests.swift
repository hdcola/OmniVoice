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
        /// The app the probe hears.
        var bundleID = "com.coppertino.Vox"
        func isOtherAudioPlaying(excluding excluded: Set<String>) -> Bool {
            !excluded.contains(bundleID) && (stale ?? playing)
        }
        func sendPlayPause() {
            presses += 1
            stale = playing // the output still shows the old state
            playing.toggle()
        }
    }

    /// Players taking direct commands; a quit one ignores them.
    private final class FakePlayers: PlayerController {
        var playing: [PlayerHandle: Bool] = [:]
        var quit: Set<PlayerHandle> = []
        var pauses: [PlayerHandle] = []
        var plays: [PlayerHandle] = []
        func reachablePlayers() -> [PlayerHandle] {
            playing.keys.filter { !quit.contains($0) }.sorted { $0.pid < $1.pid }
        }
        func isPlaying(_ player: PlayerHandle) -> Bool { playing[player] ?? false }
        func pause(_ player: PlayerHandle) -> Bool {
            guard !quit.contains(player) else { return false }
            pauses.append(player)
            playing[player] = false
            return true
        }
        func play(_ player: PlayerHandle) {
            guard !quit.contains(player) else { return }
            plays.append(player)
            playing[player] = true
        }
    }

    private let music = PlayerHandle(bundleID: "com.apple.Music", pid: 101)
    private let spotify = PlayerHandle(bundleID: "com.spotify.client", pid: 102)

    private var time: TimeInterval = 0
    private func makePauser(_ fake: Fake, players: FakePlayers = FakePlayers()) -> MediaPauser {
        MediaPauser(probe: fake, sender: fake, players: players, now: { [unowned self] in time })
    }

    func testCommandedPlayerIsPausedAndResumedWithoutTheKey() {
        let fake = Fake()
        let players = FakePlayers()
        players.playing = [music: true, spotify: false]
        let pauser = makePauser(fake, players: players)
        pauser.pauseIfPlaying()
        XCTAssertEqual(players.pauses, [music])
        pauser.resumeIfWePaused()
        XCTAssertEqual(players.plays, [music])
        XCTAssertEqual(fake.presses, 0)
        XCTAssertEqual(players.playing[spotify], false)
    }

    /// Without Accessibility the key can't be posted; direct control still works.
    func testWithoutTheKeyOnlyCommandedPlayersArePaused() {
        let fake = Fake()
        fake.playing = true
        let players = FakePlayers()
        players.playing = [spotify: true]
        let pauser = makePauser(fake, players: players)
        pauser.pauseIfPlaying(useKey: false)
        pauser.resumeIfWePaused()
        XCTAssertEqual(players.pauses, [spotify])
        XCTAssertEqual(players.plays, [spotify])
        XCTAssertEqual(fake.presses, 0)
    }

    func testIdleCommandedPlayersAreLeftAlone() {
        let fake = Fake()
        let players = FakePlayers()
        players.playing = [music: false]
        let pauser = makePauser(fake, players: players)
        pauser.pauseIfPlaying()
        pauser.resumeIfWePaused()
        XCTAssertTrue(players.pauses.isEmpty)
        XCTAssertTrue(players.plays.isEmpty)
        XCTAssertEqual(fake.presses, 0)
    }

    /// Not allowed or not running: the key handles it as before.
    func testUnreachablePlayerFallsBackToTheKey() {
        let fake = Fake()
        fake.bundleID = "com.apple.Music"
        fake.playing = true
        let players = FakePlayers()
        let pauser = makePauser(fake, players: players)
        pauser.pauseIfPlaying()
        XCTAssertFalse(fake.playing)
        time = 5
        fake.stale = nil
        pauser.resumeIfWePaused()
        XCTAssertTrue(fake.playing)
        XCTAssertEqual(fake.presses, 2)
    }

    /// The player still draining its output after the pause is not heard as
    /// a reason to press the key too.
    func testCommandedPlayerIsKeptOutOfTheKeyProbe() {
        let fake = Fake()
        fake.bundleID = "com.apple.Music"
        fake.playing = true // its output is still running
        let players = FakePlayers()
        players.playing = [music: true]
        let pauser = makePauser(fake, players: players)
        pauser.pauseIfPlaying()
        XCTAssertEqual(players.pauses, [music])
        XCTAssertEqual(fake.presses, 0)
    }

    /// Quit during the dictation: resuming neither relaunches it nor presses
    /// the key, and the next dictation starts clean.
    func testPlayerQuitDuringDictationStaysQuit() {
        let fake = Fake()
        let players = FakePlayers()
        players.playing = [music: true]
        let pauser = makePauser(fake, players: players)
        pauser.pauseIfPlaying()
        players.quit = [music]
        pauser.resumeIfWePaused()
        XCTAssertTrue(players.plays.isEmpty)
        XCTAssertEqual(fake.presses, 0)
        pauser.pauseIfPlaying()
        pauser.resumeIfWePaused()
        XCTAssertTrue(players.plays.isEmpty)
    }

    func testCommandedAndKeyPlayersAreEachHandledOnce() {
        let fake = Fake()
        fake.playing = true // Vox, only reachable by the key
        let players = FakePlayers()
        players.playing = [spotify: true]
        let pauser = makePauser(fake, players: players)
        pauser.pauseIfPlaying()
        pauser.pauseIfPlaying()
        XCTAssertEqual(players.pauses, [spotify])
        XCTAssertEqual(fake.presses, 1)
        time = 5
        fake.stale = nil
        pauser.resumeIfWePaused()
        XCTAssertEqual(players.plays, [spotify])
        XCTAssertEqual(fake.presses, 2)
        XCTAssertTrue(fake.playing)
    }

    /// Its state is current, so a dictation right after a resume pauses it
    /// at once instead of watching for it.
    func testQuickRestartPausesCommandedPlayerAtOnce() {
        let fake = Fake()
        let players = FakePlayers()
        players.playing = [music: true]
        let pauser = makePauser(fake, players: players)
        pauser.pauseIfPlaying()
        time = 5
        pauser.resumeIfWePaused()
        time = 5.3
        pauser.pauseIfPlaying()
        XCTAssertEqual(players.pauses, [music, music])
        XCTAssertEqual(players.playing[music], false)
        XCTAssertFalse(pauser.poll())
        XCTAssertEqual(fake.presses, 0)
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

    /// A paused browser keeps its output stream open: the probe still says
    /// "playing", and the music has to come back all the same.
    func testResumesEvenIfOutputStillReportsPlaying() {
        let fake = Fake()
        fake.playing = true
        let pauser = makePauser(fake)
        pauser.pauseIfPlaying()
        XCTAssertFalse(fake.playing)
        time = 5
        fake.stale = true // stream stays open while paused
        pauser.resumeIfWePaused()
        XCTAssertTrue(fake.playing)
        XCTAssertEqual(fake.presses, 2)
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

    /// The real probe has no mock to hide behind: it must at least run.
    func testCoreAudioProbeRunsAgainstTheRealSystem() {
        _ = CoreAudioPlaybackProbe().isOtherAudioPlaying()
    }

    func testOnlyDedicatedPlayersCount() {
        XCTAssertTrue(CoreAudioPlaybackProbe.playerBundleIDs.contains("com.apple.Music"))
        XCTAssertTrue(CoreAudioPlaybackProbe.playerBundleIDs.contains("com.spotify.client"))
        XCTAssertFalse(CoreAudioPlaybackProbe.playerBundleIDs.contains("com.google.Chrome.helper"))
        XCTAssertFalse(CoreAudioPlaybackProbe.playerBundleIDs.contains("systemsoundserverd"))
    }
}
