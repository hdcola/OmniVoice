import Foundation

/// Turns the trigger key's physical presses into start/finish/cancel
/// decisions for a dictation. Pure, so the hold/toggle rules are testable
/// without a keyboard.
public struct DictationTriggerMachine: Sendable {
    public enum Mode: String, CaseIterable, Sendable {
        /// Speak while the key is down; releasing it inserts the text.
        case hold
        /// Tap to start, tap again to insert.
        case toggle
    }

    public enum Action: Equatable, Sendable {
        case none
        case start
        /// Stop listening and insert what was heard.
        case finish
        /// Stop listening and throw it away.
        case cancel
    }

    public var mode: Mode
    /// A hold shorter than this is an accidental tap, not a dictation.
    public var minimumHold: TimeInterval

    private var isListening = false
    private var isHeld = false
    private var pressedAt: TimeInterval = 0

    public init(mode: Mode = .hold, minimumHold: TimeInterval = 0.3) {
        self.mode = mode
        self.minimumHold = minimumHold
    }

    public mutating func keyDown(at time: TimeInterval) -> Action {
        guard !isHeld else { return .none }
        isHeld = true
        if isListening {
            // Only toggle mode keeps listening after the key came up.
            isListening = false
            return .finish
        }
        isListening = true
        pressedAt = time
        return .start
    }

    public mutating func keyUp(at time: TimeInterval) -> Action {
        guard isHeld else { return .none }
        isHeld = false
        guard mode == .hold, isListening else { return .none }
        isListening = false
        return time - pressedAt < minimumHold ? .cancel : .finish
    }

    /// Another key was typed while the trigger was down — it was a modifier
    /// for something else (⌥ + a letter), not a request to dictate.
    public mutating func otherKeyPressed() -> Action {
        guard isHeld, isListening else { return .none }
        isListening = false
        return .cancel
    }

    /// Esc: abandon a dictation in either mode — in toggle mode the trigger
    /// is up while listening, so nothing else could cancel it.
    public mutating func escapePressed() -> Action {
        guard isListening else { return .none }
        isListening = false
        return .cancel
    }

    /// The dictation ended on its own (the microphone failed to start, ...),
    /// or the key monitor was switched off — either way no key-up for a key
    /// still down will be seen.
    public mutating func reset() {
        isListening = false
        isHeld = false
    }
}
