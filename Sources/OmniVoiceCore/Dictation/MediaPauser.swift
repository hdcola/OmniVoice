import CoreAudio
import Foundation

/// Whether some other app is producing sound right now.
public protocol MediaPlaybackProbe {
    func isOtherAudioPlaying() -> Bool
}

/// Sends the system Play/Pause media key.
public protocol MediaKeySender {
    func sendPlayPause()
}

/// Pauses whatever is playing while the user dictates, and resumes it
/// afterwards — but only if this paused it. The media key is a toggle, so it
/// is never sent blind: starting needs something audibly playing, and
/// resuming needs it to still be silent (the user may have restarted the
/// music, or something else, in the meantime).
///
/// A key press takes a moment to show up in the audio output (a pause
/// drains, a resume fades in), so right after pressing one the probe is not
/// believed: the state the press was meant to produce is assumed instead.
/// Without that, dictating twice in quick succession misreads the music's
/// state and a press lands the wrong way round.
///
/// A resume can also take longer to be heard than that. If a dictation starts
/// while one is still pending, nothing is pressed blindly (a press landing on
/// a still-paused player would start it); the dictation watches instead, and
/// pauses once the music is actually heard.
@MainActor
public final class MediaPauser {
    /// How long after our own key press the probe is not trusted.
    static let settleTime: TimeInterval = 1.5
    /// How long after a resume press the music may still turn up.
    static let resumePendingTime: TimeInterval = 6
    static let pollInterval: Duration = .milliseconds(300)

    private let probe: any MediaPlaybackProbe
    private let sender: any MediaKeySender
    private let now: () -> TimeInterval
    private var didPause = false
    /// What our last press was meant to produce, and when it was sent.
    private var lastPress: (playing: Bool, at: TimeInterval)?
    /// Until when a resume we sent may still start playing late.
    private var resumePendingUntil: TimeInterval?
    private var watchTask: Task<Void, Never>?

    public init(
        probe: any MediaPlaybackProbe = CoreAudioPlaybackProbe(),
        sender: any MediaKeySender,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.probe = probe
        self.sender = sender
        self.now = now
    }

    public func pauseIfPlaying() {
        // Already paused by us: a second press would resume it.
        guard !didPause else { return }
        if let until = resumePendingUntil, now() < until {
            // A resume may still be on its way, so no blind press — but if
            // the music is already audible there is nothing to wait for.
            if probe.isOtherAudioPlaying() {
                press(producing: false)
                didPause = true
                resumePendingUntil = nil
            } else {
                startWatching()
            }
            return
        }
        guard isPlaying() else { return }
        press(producing: false)
        didPause = true
    }

    public func resumeIfWePaused() {
        stopWatching()
        guard didPause else { return }
        didPause = false
        guard !isPlaying() else { return }
        press(producing: true)
        resumePendingUntil = now() + Self.resumePendingTime
    }

    /// One look at whether a late resume has become audible; pauses it if so.
    /// Returns false once there is nothing left to wait for.
    @discardableResult
    func poll() -> Bool {
        guard !didPause, let until = resumePendingUntil, now() < until else { return false }
        guard probe.isOtherAudioPlaying() else { return true }
        press(producing: false)
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

    private func press(producing playing: Bool) {
        sender.sendPlayPause()
        lastPress = (playing, now())
    }

    private func isPlaying() -> Bool {
        if let lastPress, now() - lastPress.at < Self.settleTime { return lastPress.playing }
        return probe.isOtherAudioPlaying()
    }
}

/// Asks CoreAudio which processes have an output running (macOS 14.4+).
public struct CoreAudioPlaybackProbe: MediaPlaybackProbe {
    public init() {}

    public func isOtherAudioPlaying() -> Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for object in Self.processObjects() {
            guard let pid = Self.pid(of: object), pid != ownPID, Self.isRunningOutput(object) else { continue }
            return true
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
        return objects
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
