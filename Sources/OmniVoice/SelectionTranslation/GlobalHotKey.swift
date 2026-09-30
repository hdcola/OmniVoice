import Carbon.HIToolbox
import Foundation

// Ported from Cida (https://github.com/Xuanwo/cida, Apache-2.0),
// `Sources/Cida/GlobalHotKey.swift`.

/// One system-wide hot key, registered with Carbon's `RegisterEventHotKey`
/// — which delivers the press to this process whichever application is
/// active, and (unlike an `NSEvent` global monitor) needs no Accessibility
/// permission and swallows the key press instead of also typing it into the
/// frontmost app. `update(to:)` swaps the combination; one the system,
/// another application, or another of this app's hot keys already holds is
/// refused and the old one stays. Without a combination (nil) nothing is
/// registered. Each instance answers only presses of its own registration,
/// so several can live side by side.
final class GlobalHotKey {
    private(set) var shortcut: GlobalShortcut?
    private let identifier: UInt32
    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?
    private let action: @MainActor () -> Void
    private var isSuspended = false

    private static var nextIdentifier: UInt32 = 1

    /// nil only when Carbon refuses to install the event handler at all. A
    /// `shortcut` the system refuses still yields an instance, with no
    /// combination registered (`shortcut` reads nil) — so a taken default
    /// doesn't leave the action with no hot key object to re-record later.
    init?(shortcut: GlobalShortcut?, action: @escaping @MainActor () -> Void) {
        self.action = action
        identifier = Self.nextIdentifier
        Self.nextIdentifier += 1

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerReference
        )
        guard handlerStatus == noErr else { return nil }

        if let shortcut, let reference = Self.register(shortcut, identifier: identifier) {
            hotKeyReference = reference
            self.shortcut = shortcut
        }
    }

    deinit {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
        }
    }

    /// Re-registers the hot key for a new combination, or releases it for
    /// nil. Returns false, with the previous combination still active, when
    /// the system refuses the new one. While suspended the new combination
    /// is only checked; it registers when the suspension ends.
    func update(to newShortcut: GlobalShortcut?) -> Bool {
        guard newShortcut != shortcut else { return true }
        let isActive = !isSuspended
        unregister()
        guard let newShortcut else {
            shortcut = nil
            return true
        }
        if let reference = Self.register(newShortcut, identifier: identifier) {
            if isActive {
                hotKeyReference = reference
            } else {
                UnregisterEventHotKey(reference)
            }
            shortcut = newShortcut
            return true
        }
        if isActive, let shortcut {
            hotKeyReference = Self.register(shortcut, identifier: identifier)
        }
        return false
    }

    /// While suspended the combination reaches the active application like
    /// any other key press — `ShortcutRecorderView` suspends every hot key
    /// while recording, so pressing the current combination records it
    /// instead of summoning the panel.
    func setSuspended(_ isSuspended: Bool) {
        self.isSuspended = isSuspended
        if isSuspended {
            unregister()
        } else if hotKeyReference == nil, let shortcut {
            hotKeyReference = Self.register(shortcut, identifier: identifier)
        }
    }

    private func unregister() {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
            self.hotKeyReference = nil
        }
    }

    private static func register(_ shortcut: GlobalShortcut, identifier: UInt32) -> EventHotKeyRef? {
        let hotKeyID = EventHotKeyID(signature: signature, id: identifier)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.modifiers.carbonFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr else { return nil }
        return reference
    }

    /// Every instance's handler sees every press; the ones that are not its
    /// own pass on to the next handler.
    private static let eventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        guard status == noErr, hotKeyID.signature == signature, hotKeyID.id == hotKey.identifier else {
            return OSStatus(eventNotHandledErr)
        }
        let action = hotKey.action
        Task { @MainActor in action() }
        return noErr
    }

    private static let signature: FourCharCode = "OMNV".utf8.reduce(0) { ($0 << 8) + FourCharCode($1) }
}
