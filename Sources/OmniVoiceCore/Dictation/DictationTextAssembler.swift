import Foundation

/// Folds a dictation's `TranscriptionEvent`s into one string: the segments
/// the engine has closed, plus whatever the open segment currently reads.
/// Pure so the joining rules are testable without an engine.
public struct DictationTextAssembler: Equatable, Sendable {
    /// Closed segments, already joined.
    public private(set) var committed = ""
    /// Text delivered through `.appended` for the open segment.
    private var appendedInSegment = ""
    /// The open segment's latest `.revised` hypothesis.
    private var revisedInSegment = ""

    public init() {}

    /// The still-open segment: an append-style engine's deltas, otherwise
    /// the latest replace-style hypothesis.
    public var pending: String {
        appendedInSegment.isEmpty ? revisedInSegment : appendedInSegment
    }

    /// Everything heard so far, trimmed.
    public var text: String {
        Self.join(committed, pending).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func apply(_ event: TranscriptionEvent) {
        switch event {
        case .appended(let text):
            appendedInSegment += text
        case .revised(let text):
            revisedInSegment = text
        case .segmentClosed(let finalAppend):
            // An append-style engine reports only the tail here; a
            // replace-style one never appended and reports the whole text.
            let segment = appendedInSegment.isEmpty ? finalAppend : appendedInSegment + finalAppend
            committed = Self.join(committed, segment)
            appendedInSegment = ""
            revisedInSegment = ""
        }
    }

    /// Joins two pieces of speech, adding a space only between two
    /// space-delimited scripts ("hello" + "world"), never next to CJK text
    /// or existing whitespace.
    static func join(_ first: String, _ second: String) -> String {
        let second = second.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = first.last else { return second }
        guard let next = second.first else { return first }
        if last.isWhitespace || isSpaceless(last) || isSpaceless(next) || closingPunctuation.contains(next) {
            return first + second
        }
        return first + " " + second
    }

    /// Punctuation that attaches to the word before it ("Hello" + ", world").
    /// Opening brackets and quotes are not here: they take the space.
    private static let closingPunctuation: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "}", "”", "…", "%"]

    /// Chinese and Japanese run words together; Korean (Hangul) separates
    /// them with spaces like Latin text, so it is deliberately not here.
    private static func isSpaceless(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80...0x9FFF, 0xF900...0xFAFF, 0x3000...0x303F, 0xFF00...0xFFEF:
                return true
            default:
                return false
            }
        }
    }
}

/// A `DictationTextAssembler` that can be fed from any thread. An engine
/// reports events from its own queue (a local model's deltas arrive on the
/// audio thread, its final tail synchronously inside `stop()`), and the text
/// must be complete the moment `stop()` returns — hopping each event to the
/// main actor first would leave the last one still in flight.
final class DictationTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var assembler = DictationTextAssembler()

    /// Applies `event` and returns the text so far.
    func apply(_ event: TranscriptionEvent) -> String {
        lock.lock()
        defer { lock.unlock() }
        assembler.apply(event)
        return assembler.text
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return assembler.text
    }
}
