import AppKit
import Carbon.HIToolbox
import OmniVoiceCore

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
    var onEscape: (() -> Void)?

    private static let eventMask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
    private static let allModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// `nonisolated(unsafe)` only so `deinit` can unregister them; every
    /// other access is on the main actor.
    private nonisolated(unsafe) var globalMonitor: Any?
    private nonisolated(unsafe) var localMonitor: Any?
    private var tracker = DictationKeyTracker()

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
        tracker.reset()
    }

    private func handle(_ event: NSEvent) {
        let result: DictationKeyTracker.Event?
        switch event.type {
        case .keyDown:
            result = tracker.keyDown(isEscape: event.keyCode == UInt16(kVK_Escape))
        case .flagsChanged:
            let flags = event.modifierFlags.intersection(Self.allModifiers)
            result = tracker.flagsChanged(
                isTriggerKey: event.keyCode == triggerKey.keyCode,
                triggerFlagHeld: flags.contains(triggerKey.flag),
                onlyTriggerModifierHeld: flags == triggerKey.flag
            )
        default:
            result = nil
        }
        switch result {
        case .down: onKeyDown?(event.timestamp)
        case .up: onKeyUp?(event.timestamp)
        case .otherKey: onOtherKey?()
        case .escape: onEscape?()
        case nil: break
        }
    }
}
