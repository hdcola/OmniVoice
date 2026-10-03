import AppKit
import Carbon.HIToolbox

/// Swallows Return while a toggle-mode dictation is listening, so pressing it
/// ends the dictation (and sends the text) instead of reaching the focused
/// app a moment before the text does. `DictationKeyMonitor` can't do this —
/// `NSEvent` monitors only observe — so this installs an active event tap,
/// and only for the length of a dictation: an active tap sits in front of
/// every keystroke, which isn't something to leave running.
///
/// Needs the Accessibility permission (dictation already asks for it to
/// paste). Without it the tap can't be made and Return simply types.
@MainActor
final class DictationReturnInterceptor {
    /// Marks the Return the app posts itself, so the tap lets it through.
    static let ownEventMarker: Int64 = 0x4F56_5254

    /// Called on Return; true means the key was used and must be swallowed.
    var shouldSwallow: (() -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// A swallowed Return is down: its repeats and its release are swallowed
    /// too, even after the dictation ended, so no half of the key leaks out.
    private var swallowingHeldReturn = false
    private var stopWhenReleased = false

    var isRunning: Bool { tap != nil }

    func start() {
        stopWhenReleased = false
        guard tap == nil, SelectedTextReader.isAccessibilityTrusted else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let interceptor = Unmanaged<DictationReturnInterceptor>.fromOpaque(refcon).takeUnretainedValue()
            let swallowed = MainActor.assumeIsolated { interceptor.handle(type: type, event: event) }
            return swallowed ? nil : Unmanaged.passUnretained(event)
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        self.source = source
    }

    /// Removes the tap — once a Return that is still held has come up.
    func stop() {
        if swallowingHeldReturn {
            stopWhenReleased = true
            // A release that never arrives must not leave the tap installed.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.swallowingHeldReturn = false
                self?.removeTap()
            }
            return
        }
        removeTap()
    }

    private func removeTap() {
        stopWhenReleased = false
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        self.tap = nil
        source = nil
    }

    /// True when the event must not reach the focused app.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter,
              event.getIntegerValueField(.eventSourceUserData) != Self.ownEventMarker
        else { return false }
        switch type {
        case .keyDown:
            if swallowingHeldReturn { return true }
            guard shouldSwallow?() == true else { return false }
            swallowingHeldReturn = true
            return true
        case .keyUp:
            guard swallowingHeldReturn else { return false }
            swallowingHeldReturn = false
            if stopWhenReleased { removeTap() }
            return true
        default:
            return false
        }
    }
}
