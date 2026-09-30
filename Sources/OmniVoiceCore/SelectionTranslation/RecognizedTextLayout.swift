import CoreGraphics
import Foundation

// Ported from Cida (https://github.com/Xuanwo/cida, Apache-2.0),
// `Sources/Cida/TextRecognition.swift`.

/// One line of text Vision recognized in a screenshot, framed in the image's
/// unit square with the origin at the top-left.
public struct RecognizedLine: Equatable, Sendable {
    public let text: String
    public let frame: CGRect

    public init(text: String, frame: CGRect) {
        self.text = text
        self.frame = frame
    }
}

/// Rebuilds reading order and line breaks from recognized lines, so ⌥S
/// screenshot translation (see the app's `ScreenTextRecognizer`) hands
/// `SelectionTranslator` paragraphs rather than one visual line per row:
/// lines that share a row join with a space, and consecutive rows join as
/// one wrapped paragraph, the way the language wraps, unless the text broke
/// the line itself. A row ends a line when the gap below it is clearly wider
/// than the text's line spacing, when the next row starts a list item, or
/// when the next row's first word would still have fit on it.
public enum RecognizedTextLayout {
    public static func text(from lines: [RecognizedLine]) -> String? {
        let lines = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return nil }

        let rows = rows(of: lines)
        let typicalHeight = median(rows.map(\.frame.height))
        let rightEdge = rows.map(\.frame.maxX).max() ?? 0
        var text = rows[0].text
        for (previous, row) in zip(rows, rows.dropFirst()) {
            let gap = row.frame.minY - previous.frame.maxY
            if gap > typicalHeight * 0.8 || startsListItem(row.text)
                || hasRoom(for: row, after: previous, rightEdge: rightEdge)
            {
                text += "\n" + row.text
            } else {
                text = joinWrapped(text, row.text)
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private struct Row {
        var text: String
        var frame: CGRect
    }

    /// Lines whose vertical centres fall within half a line of each other are
    /// one row, read left to right.
    private static func rows(of lines: [RecognizedLine]) -> [Row] {
        let sorted = lines.sorted { $0.frame.midY < $1.frame.midY }
        var rows: [[RecognizedLine]] = []
        for line in sorted {
            if let last = rows.last?.last,
               abs(line.frame.midY - last.frame.midY) < min(line.frame.height, last.frame.height) / 2
            {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { row in
            let ordered = row.sorted { $0.frame.minX < $1.frame.minX }
            let text = ordered.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            let frame = ordered.dropFirst().reduce(ordered[0].frame) { $0.union($1.frame) }
            return Row(text: text, frame: frame)
        }
    }

    /// A wrapped line only ends early when the next word does not fit, so room
    /// for that word plus some slack means the line was broken on purpose.
    /// Widths are estimated from the row's average character width.
    private static func hasRoom(for row: Row, after previous: Row, rightEdge: CGFloat) -> Bool {
        let characterWidth = previous.frame.width / CGFloat(previous.text.count)
        let room = rightEdge - previous.frame.maxX
        let firstWord: Int
        if let first = row.text.first, first.isCJK {
            firstWord = 1
        } else {
            firstWord = row.text.prefix { !$0.isWhitespace }.count
        }
        return room > characterWidth * (CGFloat(firstWord) * 1.4 + 1)
    }

    /// Bullets, dashes and numbers that open a list item, such as "• ", "- ",
    /// "2. " and "3、".
    private static func startsListItem(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        if "•◦▪▫‣∙·●○■□▸►".contains(first) {
            return true
        }
        let rest = text.dropFirst()
        if "-*+".contains(first) {
            return rest.first == " "
        }
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard (1...3).contains(digits.count) else { return false }
        let marker = text.dropFirst(digits.count)
        if marker.first == "、" {
            return true
        }
        return (marker.first == "." || marker.first == ")") && marker.dropFirst().first == " "
    }

    /// Chinese and Japanese wrap without spaces; Latin text wraps at a space,
    /// or inside a word after a hyphen.
    static func joinWrapped(_ head: String, _ tail: String) -> String {
        guard let last = head.last, let first = tail.first else { return head + tail }
        if last.isCJK || first.isCJK {
            return head + tail
        }
        if last == "-", head.dropLast().last?.isLetter == true, first.isLowercase {
            return String(head.dropLast()) + tail
        }
        return head + " " + tail
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
}

private extension Character {
    /// Han ideographs, kana, and CJK punctuation or full-width forms.
    var isCJK: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
                return true
            default:
                return false
            }
        }
    }
}
