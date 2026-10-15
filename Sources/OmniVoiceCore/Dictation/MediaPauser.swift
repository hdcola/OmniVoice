import AppKit
import CoreAudio

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
@MainActor
public final class MediaPauser {
    private let probe: any MediaPlaybackProbe
    private let sender: any MediaKeySender
    private var didPause = false

    public init(
        probe: any MediaPlaybackProbe = CoreAudioPlaybackProbe(),
        sender: any MediaKeySender = SystemMediaKeySender()
    ) {
        self.probe = probe
        self.sender = sender
    }

    public func pauseIfPlaying() {
        // Already paused by us: a second press would resume it.
        guard !didPause, probe.isOtherAudioPlaying() else { return }
        sender.sendPlayPause()
        didPause = true
    }

    public func resumeIfWePaused() {
        guard didPause else { return }
        didPause = false
        guard !probe.isOtherAudioPlaying() else { return }
        sender.sendPlayPause()
    }
}

/// Asks CoreAudio which processes have an output running (macOS 14.4+).
public struct CoreAudioPlaybackProbe: MediaPlaybackProbe {
    public init() {}

    public func isOtherAudioPlaying() -> Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for object in Self.processObjects() {
            guard Self.pid(of: object) != ownPID, Self.isRunningOutput(object) else { continue }
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

/// Posts the Play/Pause key (`NX_KEYTYPE_PLAY`) as a system-defined event.
public struct SystemMediaKeySender: MediaKeySender {
    public init() {}

    public func sendPlayPause() {
        let keyType = 16 // NX_KEYTYPE_PLAY
        for isDown in [true, false] {
            let flags = isDown ? 0xA00 : 0xB00
            NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (keyType << 16) | flags,
                data2: -1
            )?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
