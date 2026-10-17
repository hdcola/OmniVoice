import CoreAudio
import Foundation

/// Whether some other app is producing sound right now.
public protocol MediaPlaybackProbe {
    /// Apps in `excluded` (bundle IDs) don't count.
    func isOtherAudioPlaying(excluding excluded: Set<String>) -> Bool
}

extension MediaPlaybackProbe {
    func isOtherAudioPlaying() -> Bool { isOtherAudioPlaying(excluding: []) }
}

/// Sends the system Play/Pause media key.
public protocol MediaKeySender {
    func sendPlayPause()
}

/// One running instance of a player that can be told what to do directly.
public struct PlayerHandle: Hashable, Sendable {
    public let bundleID: String
    public let pid: pid_t

    public init(bundleID: String, pid: pid_t) {
        self.bundleID = bundleID
        self.pid = pid
    }
}

/// Players that take explicit Play and Pause commands and report their
/// state, so nothing is toggled blind. Addressed by process, so a command
/// never launches an app, and never asks for permission: a player the user
/// hasn't allowed is simply not reachable.
public protocol PlayerController {
    /// Running players this may control right now.
    func reachablePlayers() -> [PlayerHandle]
    func isPlaying(_ player: PlayerHandle) -> Bool
    /// Whether the player took the command.
    func pause(_ player: PlayerHandle) -> Bool
    /// Does nothing if the player has quit since.
    func play(_ player: PlayerHandle)
}

/// No directly controllable players: everything goes through the media key.
public struct NoPlayerController: PlayerController {
    public init() {}
    public func reachablePlayers() -> [PlayerHandle] { [] }
    public func isPlaying(_ player: PlayerHandle) -> Bool { false }
    public func pause(_ player: PlayerHandle) -> Bool { false }
    public func play(_ player: PlayerHandle) {}
}

/// Pauses whatever is playing while the user dictates, and resumes it
/// afterwards — but only if this paused it.
///
/// Players the `PlayerController` reaches are paused and resumed by their own
/// commands, each exactly the one it paused. Everything else falls back to
/// the media key, which goes to whichever app owns "now playing" and is a
/// toggle, so it
/// is never sent blind: starting needs something audibly playing, and
/// resuming is unconditional once this has paused.
///
/// A resume can take a moment to be heard. If a dictation starts while one is
/// still pending (`resumePendingTime`), nothing is pressed blindly (a press
/// landing on a still-paused player would start it): it pauses at once if the
/// music is already audible, and otherwise watches and pauses once it is.
@MainActor
public final class MediaPauser {
    /// How long after a resume press the music may still turn up.
    static let resumePendingTime: TimeInterval = 6
    static let pollInterval: Duration = .milliseconds(300)

    private let probe: any MediaPlaybackProbe
    private let sender: any MediaKeySender
    private let players: any PlayerController
    /// Players this paused by command, to resume by command.
    private var pausedPlayers: [PlayerHandle] = []
    /// Players the controller handles, left out of the media key's probe so
    /// the key isn't pressed for them too.
    private var commandedBundleIDs: Set<String> = []
    private let now: () -> TimeInterval
    private var didPause = false
    /// Until when a resume we sent may still start playing late.
    private var resumePendingUntil: TimeInterval?
    private var watchTask: Task<Void, Never>?

    public init(
        probe: any MediaPlaybackProbe = CoreAudioPlaybackProbe(),
        sender: any MediaKeySender,
        players: any PlayerController = NoPlayerController(),
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.probe = probe
        self.sender = sender
        self.players = players
        self.now = now
    }

    /// `useKey` false leaves the media key out (it can't be posted) and
    /// pauses only the players controlled directly.
    public func pauseIfPlaying(useKey: Bool = true) {
        pauseControlledPlayers()
        if useKey { pauseByKey() }
    }

    private func pauseControlledPlayers() {
        let reachable = players.reachablePlayers()
        commandedBundleIDs = Set(reachable.map(\.bundleID))
        // Its reported state is current, so no settling to wait for here.
        for player in reachable where !pausedPlayers.contains(player) && players.isPlaying(player) {
            if players.pause(player) { pausedPlayers.append(player) }
        }
    }

    private func pauseByKey() {
        // Already paused by us: a second press would resume it.
        guard !didPause else { return }
        if let until = resumePendingUntil, now() < until {
            // A resume may still be on its way, so no blind press — but if
            // the music is already audible there is nothing to wait for.
            if probe.isOtherAudioPlaying(excluding: commandedBundleIDs) {
                sender.sendPlayPause()
                didPause = true
                resumePendingUntil = nil
            } else {
                startWatching()
            }
            return
        }
        guard probe.isOtherAudioPlaying(excluding: commandedBundleIDs) else { return }
        sender.sendPlayPause()
        didPause = true
    }

    public func resumeIfWePaused() {
        stopWatching()
        // By process: a player quit meanwhile stays quit.
        for player in pausedPlayers { players.play(player) }
        pausedPlayers = []
        guard didPause else { return }
        didPause = false
        // Never second-guessed with the probe: a paused browser keeps its
        // audio output open, so "something is outputting" says nothing about
        // whether the music is playing, and skipping this press would leave
        // it paused (and make the next dictation's press start it).
        sender.sendPlayPause()
        resumePendingUntil = now() + Self.resumePendingTime
    }

    /// One look at whether a late resume has become audible; pauses it if so.
    /// Returns false once there is nothing left to wait for.
    @discardableResult
    func poll() -> Bool {
        guard !didPause, let until = resumePendingUntil, now() < until else { return false }
        guard probe.isOtherAudioPlaying(excluding: commandedBundleIDs) else { return true }
        sender.sendPlayPause()
        didPause = true
        resumePendingUntil = nil
        return false
    }

    private func startWatching() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            // Clear the handle once the loop is done on its own, so a later
            // dictation can watch again. A cancelled task leaves it alone:
            // `stopWatching` already cleared it, and a newer task may own it.
            defer { if !Task.isCancelled { self?.watchTask = nil } }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let self, poll() else { break }
            }
        }
    }

    private func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        // The dictation is over: a late resume is now just the music coming back.
        resumePendingUntil = nil
    }
}

/// Asks CoreAudio which processes have an output running (macOS 14.4+).
public struct CoreAudioPlaybackProbe: MediaPlaybackProbe {
    public init() {}

    /// Dedicated players that own "now playing". Only these count: with no
    /// such app, the Play/Pause key makes macOS launch Music, which steals
    /// the focus and breaks the typing. Browsers are left out — a tab can
    /// hold an audio output open in silence, and the system's now-playing
    /// state is closed to third-party apps, so playback can't be confirmed.
    static let playerBundleIDs: Set<String> = [
        "com.apple.Music",
        "com.apple.iTunes",
        "com.apple.podcasts",
        "com.apple.TV",
        "com.spotify.client",
        "org.videolan.vlc",
        "com.colliderli.iina",
        "com.netease.163music",
        "com.tencent.QQMusicMac",
        "com.tencent.QQMusic",
        "com.kugou.mac.KuGou",
        "com.coppertino.Vox",
        "com.tidal.desktop",
        "com.amazon.music",
        "com.deezer.Deezer",
        "fm.last.Last.fm",
        "io.mpv",
    ]

    public func isOtherAudioPlaying(excluding excluded: Set<String>) -> Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for object in Self.processObjects() {
            // Cheapest read first: nearly every process is silent.
            guard Self.isRunningOutput(object) else { continue }
            guard let pid = Self.pid(of: object), pid > 0, pid != ownPID else { continue }
            if let bundleID = Self.bundleID(of: object), Self.playerBundleIDs.contains(bundleID),
               !excluded.contains(bundleID) { return true }
        }
        return false
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr
        else { return [] }
        // A process may have gone between the size query and the read.
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bundleID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &bundleID) == noErr,
              let bundleID else { return nil }
        return bundleID.takeRetainedValue() as String
    }

    private static func pid(of object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr else { return nil }
        return pid
    }

    private static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}
