import AppKit
import OmniVoiceCore

/// Posts the Play/Pause key (`NX_KEYTYPE_PLAY`) as a system-defined event.
struct SystemMediaKeySender: MediaKeySender {
    init() {}

    func sendPlayPause() {
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
