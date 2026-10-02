import AppKit
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

    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    /// Shows the system's Input Monitoring prompt (macOS shows it once).
    static func requestPermission() {
        _ = CGRequestListenEventAccess()
    }

    private var detector = DoubleCopyDetector()
    private var monitor: Any?
    private var lastFrontmostProcess: pid_t?
    private let onDoubleCopy: @MainActor () -> Void

    init(onDoubleCopy: @escaping @MainActor () -> Void) {
        self.onDoubleCopy = onDoubleCopy
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

    private func handle(_ event: NSEvent) {
        guard
            !event.isARepeat,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers?.lowercased() == "c"
        else {
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
