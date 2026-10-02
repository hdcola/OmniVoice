import Foundation

/// Reads the keyboard's modifier-flag changes and key presses and says what
/// they mean for the trigger key: it went down, it came up, or something else
/// was pressed while it was held. Pure so the awkward cases (left and right
/// copies of a modifier, chords, a missed release) are testable.
///
/// A modifier's flag stays set while *either* copy of it is held, so a flag
/// change from the trigger key itself is read as a toggle of that key rather
/// than inferred from the flag alone.
public struct DictationKeyTracker: Sendable {
    public enum Event: Equatable, Sendable {
        case down
        case up
        /// Another key or modifier joined the trigger — it was part of a
        /// chord, not a request to dictate.
        case otherKey
        case escape
    }

    private var isDown = false

    public init() {}

    /// - Parameters:
    ///   - isTriggerKey: the event is the trigger key itself changing state.
    ///   - triggerFlagHeld: the trigger's modifier flag is set after the event.
    ///   - onlyTriggerModifierHeld: no modifier other than the trigger's is set.
    public mutating func flagsChanged(isTriggerKey: Bool, triggerFlagHeld: Bool, onlyTriggerModifierHeld: Bool) -> Event? {
        if isTriggerKey {
            if isDown {
                isDown = false
                return .up
            }
            // Another modifier already held (⌘⌥…) makes this a chord.
            guard triggerFlagHeld, onlyTriggerModifierHeld else { return nil }
            isDown = true
            return .down
        }
        guard isDown else { return nil }
        // Every copy of the trigger's modifier is up, yet no release of the
        // trigger itself was seen — it was missed.
        if !triggerFlagHeld {
            isDown = false
            return .up
        }
        return .otherKey
    }

    public mutating func keyDown(isEscape: Bool) -> Event? {
        if isEscape { return .escape }
        // ⌥ + a letter types a special character, ⌘ + a letter is a shortcut.
        return isDown ? .otherKey : nil
    }

    public mutating func reset() {
        isDown = false
    }
}
