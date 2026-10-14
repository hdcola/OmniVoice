import Foundation

/// Decides when a menu-bar-only app should show a Dock icon: while at least
/// one regular window (setup wizard, Settings, ...) is open. Pure bookkeeping
/// — the app turns `Change` into `NSApp.setActivationPolicy`.
public struct DockPresenceTracker: Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        /// The first window opened: show the Dock icon.
        case showDock
        /// The last window closed: go back to menu-bar only.
        case hideDock
    }

    private var openWindows: Set<String> = []

    public init() {}

    public var openCount: Int { openWindows.count }

    /// Marks `id` open. Idempotent (a window re-shown or re-keyed is not
    /// counted twice). Returns `.showDock` only for the 0 → 1 transition.
    public mutating func windowOpened(_ id: String) -> Change? {
        let wasEmpty = openWindows.isEmpty
        openWindows.insert(id)
        return wasEmpty ? .showDock : nil
    }

    /// Marks `id` closed. Unknown ids are ignored. Returns `.hideDock` only
    /// when the last open window closes.
    public mutating func windowClosed(_ id: String) -> Change? {
        guard openWindows.remove(id) != nil else { return nil }
        return openWindows.isEmpty ? .hideDock : nil
    }
}
