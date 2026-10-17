import CoreAudio
import Foundation

/// Silences other apps' audio for the length of a dictation.
public protocol AudioMuter {
    /// Whether anything was muted.
    func mute() -> Bool
    func unmute()
}

/// Mutes nothing.
public struct NoAudioMuter: AudioMuter {
    public init() {}
    public func mute() -> Bool { false }
    public func unmute() {}
}

/// Mutes browsers with a CoreAudio process tap instead of pausing them: a
/// browser can't be told to pause, and the play/pause key may wake Music
/// instead. The video keeps playing, without sound.
///
/// A muted tap only silences while something reads it, so it is hung on a
/// private aggregate device with an IO proc that drops what it gets. Reading
/// needs the system-audio permission, but muting doesn't — without it the
/// tap yields silence, the browser still goes quiet, and nothing is asked.
/// The tap and device belong to this process, so if it dies the sound
/// comes back.
public final class CoreAudioBrowserMuter: AudioMuter {
    /// Matched as prefixes, to take in the `.helper` processes that actually
    /// play the sound. Safari's comes out of the WebKit GPU process.
    static let browserBundleIDPrefixes = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.apple.WebKit.GPU",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
    ]

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "org.hdcola.omnivoice.browser-mute")

    public init() {}

    /// Muting a silent tab costs nothing, so an open output is enough. One
    /// that is also recording is in a call, and the other side must stay
    /// audible.
    static func shouldMute(bundleID: String, isRunningOutput: Bool, isRunningInput: Bool) -> Bool {
        isRunningOutput && !isRunningInput && browserBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }

    public func mute() -> Bool {
        guard tap == kAudioObjectUnknown else { return true }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let targets = AudioProcesses.objects().filter { object in
            // Cheapest read first: nearly every process is silent.
            guard AudioProcesses.isRunningOutput(object),
                  let pid = AudioProcesses.pid(of: object), pid > 0, pid != ownPID,
                  let bundleID = AudioProcesses.bundleID(of: object) else { return false }
            return Self.shouldMute(bundleID: bundleID, isRunningOutput: true, isRunningInput: AudioProcesses.isRunningInput(object))
        }
        guard !targets.isEmpty else { return false }

        let description = CATapDescription(stereoMixdownOfProcesses: targets)
        description.muteBehavior = .muted
        description.isPrivate = true
        description.name = "OmniVoice dictation mute"
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else {
            tap = AudioObjectID(kAudioObjectUnknown)
            return false
        }
        let deviceDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OmniVoice dictation mute",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(deviceDescription as CFDictionary, &device) == noErr,
              AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, ioQueue, { _, _, _, _, _ in }) == noErr,
              AudioDeviceStart(device, ioProc) == noErr
        else {
            unmute()
            return false
        }
        return true
    }

    public func unmute() {
        if device != kAudioObjectUnknown {
            if let ioProc {
                AudioDeviceStop(device, ioProc)
                AudioDeviceDestroyIOProcID(device, ioProc)
            }
            AudioHardwareDestroyAggregateDevice(device)
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        ioProc = nil
        device = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }
}
