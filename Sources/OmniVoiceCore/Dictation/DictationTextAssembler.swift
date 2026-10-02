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
        if last.isWhitespace || isSpaceless(last) || isSpaceless(next) { return first + second }
        return first + " " + second
    }

    private static func isSpaceless(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x3000...0x303F, 0xFF00...0xFFEF:
                return true
            default:
                return false
            }
        }
    }
}
