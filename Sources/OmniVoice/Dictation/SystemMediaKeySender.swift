import AppKit
import OmniVoiceCore

/// Posts the Play/Pause key (`NX_KEYTYPE_PLAY`) as a system-defined event.
struct SystemMediaKeySender: MediaKeySender {
    init() {}

    // IOKit's `ev_keymap.h` / `NX_*` values, which Swift doesn't import.
    private static let keyTypePlay = 16 // NX_KEYTYPE_PLAY
    private static let subtypeAuxControlButtons: Int16 = 8 // NX_SUBTYPE_AUX_CONTROL_BUTTONS
    private static let keyDownState = 0xA // NX_KEYDOWN
    private static let keyUpState = 0xB // NX_KEYUP

    private static let musicBundleID = "com.apple.Music"

    func sendPlayPause() {
        // With no app owning "now playing", macOS answers the key by launching
        // Music. The audio probe can't tell (a browser tab may hold an output
        // open silently), so a Music this press started is quit again.
        let musicWasRunning = Self.isMusicRunning
        post()
        guard !musicWasRunning else { return }
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                if let music = NSRunningApplication.runningApplications(withBundleIdentifier: Self.musicBundleID).first {
                    music.terminate()
                    return
                }
            }
        }
    }

    private static var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleID).isEmpty
    }

    private func post() {
        for isDown in [true, false] {
            // The key's state rides in bits 8–15 of both `data1` and the flags.
            let state = (isDown ? Self.keyDownState : Self.keyUpState) << 8
            NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: Self.subtypeAuxControlButtons,
                data1: (Self.keyTypePlay << 16) | state,
                data2: -1
            )?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
