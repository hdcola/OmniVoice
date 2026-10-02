import AppKit
import Carbon.HIToolbox
import CoreGraphics
import OmniVoiceCore

/// Calls `onDoubleCopy` when the user presses ⌘C twice in quick succession in
/// another application. The applications do the copying themselves, so the
/// text is simply on the pasteboard by the time the second press lands — no
/// Accessibility read and no synthesized key event.
///
/// Watching keystrokes in other applications needs the Input Monitoring
/// permission; without it the global monitor is installed but never hears
/// anything.
@MainActor
final class DoubleCopyMonitor {
    /// Time for the application to finish writing the second copy before the
    /// pasteboard is read.
    static let copySettleDelay: Duration = .milliseconds(120)

    /// Caps Lock, Fn and the numeric-pad flag don't change what ⌘C means.
    private static let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .control, .option]

    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    /// Shows the system's Input Monitoring prompt (macOS shows it once).
    static func requestPermission() {
        _ = CGRequestListenEventAccess()
    }

    private var detector = DoubleCopyDetector()
    /// `nonisolated(unsafe)` only so `deinit` can unregister it; every other
    /// access is on the main actor.
    private nonisolated(unsafe) var monitor: Any?
    private var lastFrontmostProcess: pid_t?
    private let onDoubleCopy: @MainActor () -> Void

    init(onDoubleCopy: @escaping @MainActor () -> Void) {
        self.onDoubleCopy = onDoubleCopy
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        detector.reset()
    }

    /// The "c" of ⌘C. On a layout whose letters aren't Latin (Russian, ...)
    /// the key's character isn't "c", so the physical C key counts there; on
    /// a Latin layout the character decides, which keeps Dvorak right.
    private static func isCopyKey(_ event: NSEvent) -> Bool {
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return false }
        if characters.lowercased() == "c" { return true }
        return !characters.allSatisfy(\.isASCII) && event.keyCode == UInt16(kVK_ANSI_C)
    }

    private func handle(_ event: NSEvent) {
        guard
            !event.isARepeat,
            event.modifierFlags.intersection(Self.relevantModifiers) == .command,
            Self.isCopyKey(event)
        else {
            // Any other key between two ⌘C presses breaks the sequence.
            detector.reset()
            return
        }
        // Two copies in different applications are not a double.
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontmost != lastFrontmostProcess {
            detector.reset()
            lastFrontmostProcess = frontmost
        }
        if detector.registerCopy(at: event.timestamp) {
            onDoubleCopy()
        }
    }
}
