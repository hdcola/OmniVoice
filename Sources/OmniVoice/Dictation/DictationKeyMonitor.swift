import AppKit
import Carbon.HIToolbox

/// The single modifier key that triggers dictation. A bare modifier never
/// types anything on its own, so it can double as a push-to-talk key without
/// swallowing a character.
enum DictationTriggerKey: String, CaseIterable, Identifiable {
    case rightOption
    case rightCommand
    case rightControl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: return "右 ⌥ Option"
        case .rightCommand: return "右 ⌘ Command"
        case .rightControl: return "右 ⌃ Control"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return UInt16(kVK_RightOption)
        case .rightCommand: return UInt16(kVK_RightCommand)
        case .rightControl: return UInt16(kVK_RightControl)
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption: return .option
        case .rightCommand: return .command
        case .rightControl: return .control
        }
    }
}

/// Reports the trigger key going down and up, and any other key typed in
/// between. Watching other applications' keystrokes needs the Input
/// Monitoring permission (like `DoubleCopyMonitor`); without it only this
/// app's own windows are heard.
@MainActor
final class DictationKeyMonitor {
    var triggerKey: DictationTriggerKey = .rightOption
    var onKeyDown: ((TimeInterval) -> Void)?
    var onKeyUp: ((TimeInterval) -> Void)?
    var onOtherKey: (() -> Void)?

    private static let eventMask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
    private static let allModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// `nonisolated(unsafe)` only so `deinit` can unregister them; every
    /// other access is on the main actor.
    private nonisolated(unsafe) var globalMonitor: Any?
    private nonisolated(unsafe) var localMonitor: Any?
    private var isDown = false

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    var isRunning: Bool { globalMonitor != nil }

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.eventMask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        // Global monitors never hear this app's own windows (Settings).
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.eventMask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            // ⌥ + a letter types a special character, ⌘ + a letter is a
            // shortcut: the trigger was a modifier there, not a request.
            if isDown { onOtherKey?() }
        case .flagsChanged where event.keyCode == triggerKey.keyCode:
            let flags = event.modifierFlags.intersection(Self.allModifiers)
            if flags.contains(triggerKey.flag) {
                // Another modifier already held (⌘⌥…) makes this a chord.
                guard !isDown, flags == triggerKey.flag else { return }
                isDown = true
                onKeyDown?(event.timestamp)
            } else if isDown {
                isDown = false
                onKeyUp?(event.timestamp)
            }
        case .flagsChanged:
            // A different modifier joining the trigger turns it into a chord.
            if isDown, event.modifierFlags.intersection(Self.allModifiers).contains(triggerKey.flag) {
                onOtherKey?()
            }
        default:
            break
        }
    }
}
