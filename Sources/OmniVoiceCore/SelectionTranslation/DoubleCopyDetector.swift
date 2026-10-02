import Foundation

/// Recognizes "⌘C twice in quick succession" from a stream of copy presses.
/// Pure timing logic — the app-side listener feeds it each ⌘C and acts when
/// `registerCopy(at:)` says the press completed a double.
public struct DoubleCopyDetector: Sendable {
    /// The longest gap between two presses that still counts as a double.
    public static let defaultInterval: TimeInterval = 0.35

    /// Presses closer together than this are switch bounce or a key-repeat
    /// macro, not two deliberate presses.
    public static let defaultMinimumInterval: TimeInterval = 0.05

    public let interval: TimeInterval
    public let minimumInterval: TimeInterval
    private var lastCopy: TimeInterval?

    public init(
        interval: TimeInterval = DoubleCopyDetector.defaultInterval,
        minimumInterval: TimeInterval = DoubleCopyDetector.defaultMinimumInterval
    ) {
        self.interval = interval
        self.minimumInterval = minimumInterval
    }

    /// `time` is any monotonic clock in seconds. Returns true when this press
    /// follows the previous one within `interval` (and no sooner than
    /// `minimumInterval`; a bounce is dropped without disturbing the pair); a double consumes both
    /// presses, so a third quick press starts a new pair instead of firing
    /// again.
    public mutating func registerCopy(at time: TimeInterval) -> Bool {
        if let lastCopy, time >= lastCopy, time - lastCopy < minimumInterval {
            return false
        }
        if let lastCopy, time >= lastCopy, time - lastCopy <= interval {
            self.lastCopy = nil
            return true
        }
        lastCopy = time
        return false
    }

    /// Forgets the previous press, e.g. when the user switches application
    /// between two copies.
    public mutating func reset() {
        lastCopy = nil
    }
}
