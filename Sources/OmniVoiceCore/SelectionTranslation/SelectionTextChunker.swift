import Foundation
import NaturalLanguage

/// One piece of a selection, as `SelectionTextChunker` splits it for
/// translation.
public enum SelectionTextPiece: Equatable, Sendable {
    /// Text to translate — one paragraph, or one sentence-aligned chunk of
    /// an over-long paragraph.
    case text(String)
    /// Line breaks/blank lines between paragraphs, copied into the result
    /// as-is so the translation keeps the selection's layout.
    case verbatim(String)
    /// Between two chunks of the same over-long paragraph — joined with a
    /// space or nothing, depending on the target language
    /// (`SelectionLanguageDirection.joinsWithoutSpaces(_:)`), since the
    /// source's own separator says nothing about the target's.
    case softBreak
}

/// Splits a selection into paragraph-sized pieces for
/// `SelectionTranslator`, translated one at a time.
///
/// Why split at all rather than send the whole selection in one call:
/// - `HYMT15Translator` has a fixed 4096-token context shared between
///   prompt and output, and refuses (rather than trims) an over-budget
///   input — see `translateText(_:targetLanguage:sourceIsChinese:)`'s doc.
/// - Neither engine streams tokens, so translating paragraph by paragraph
///   is what lets the panel show the first paragraph's translation while
///   the rest are still being translated.
/// - Per-paragraph calls keep the model from merging or dropping line
///   breaks, which a small translation model does freely on long inputs.
public enum SelectionTextChunker {
    /// Comfortably below what `HYMT15Translator`'s budget fits (a Chinese
    /// character is ~1 token and the translation needs room too), while
    /// still long enough that ordinary paragraphs stay whole.
    public static let defaultMaxCharacters = 800

    public static func pieces(of text: String, maxCharacters: Int = defaultMaxCharacters) -> [SelectionTextPiece] {
        var pieces: [SelectionTextPiece] = []
        var pendingBreaks = ""
        for line in logicalLines(of: text) {
            let content = line.trimmingCharacters(in: .whitespaces)
            if content.isEmpty {
                pendingBreaks += "\n"
                continue
            }
            if !pieces.isEmpty {
                // The line break that ended the previous paragraph, plus any
                // blank lines after it.
                pieces.append(.verbatim(pendingBreaks + "\n"))
            }
            pendingBreaks = ""
            // A list marker is layout, not text: HY-MT1.5 drops one about
            // as often as it keeps it, so it's copied into the result
            // instead of being sent to the model.
            var body = Substring(content)
            if let marker = body.firstMatch(of: listMarker) {
                pieces.append(.verbatim(String(marker.output)))
                body = body[marker.range.upperBound...]
            }
            let chunks = chunk(String(body), maxCharacters: maxCharacters)
            for (index, chunk) in chunks.enumerated() {
                if index > 0 { pieces.append(.softBreak) }
                pieces.append(.text(chunk))
            }
        }
        return pieces
    }

    /// Hard-wrapped text (Markdown source, email, terminal output — lines
    /// broken at a fixed width, not where a sentence ends) rejoined into
    /// one line per paragraph, so a sentence isn't cut in two and
    /// translated as two unrelated fragments. Blank lines come back as
    /// empty strings.
    ///
    /// Within a block of consecutive non-blank lines, a line continues the
    /// previous one when the previous one ran close to the block's widest
    /// line (it wrapped because it was full) — unless this one starts a
    /// list item or a Markdown heading/quote. Short lines (chat messages,
    /// addresses, poetry) are never joined: a block is only treated as
    /// wrapped once its widest line is at least `minimumWrapWidth` long.
    static func logicalLines(of text: String) -> [String] {
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [String] = []
        var block: [String] = []
        func flushBlock() {
            let widest = block.map { displayWidth(of: $0.trimmingCharacters(in: .whitespaces)) }.max() ?? 0
            var previousWasFull = false
            for line in block {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let startsNewItem = trimmed.firstMatch(of: listMarker) != nil
                    || trimmed.hasPrefix("#") || trimmed.hasPrefix(">")
                if previousWasFull, !startsNewItem, let last = result.popLast() {
                    result.append(joinWrapped(last, trimmed))
                } else {
                    result.append(line)
                }
                previousWasFull = widest >= minimumWrapWidth && Double(displayWidth(of: trimmed)) >= Double(widest) * 0.7
            }
            block.removeAll()
        }
        for line in rawLines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushBlock()
                result.append("")
            } else {
                block.append(line)
            }
        }
        flushBlock()
        return result
    }

    /// In `displayWidth(of:)` columns.
    static let minimumWrapWidth = 50

    /// Monospace columns: a CJK character takes two, as it does in the
    /// terminals/editors that hard-wrap text in the first place.
    private static func displayWidth(of text: String) -> Int {
        text.reduce(0) { $0 + ($1.isCJKForWrapping ? 2 : 1) }
    }

    /// Chinese and Japanese wrap without spaces; everything else wraps at
    /// one (same rule as `RecognizedTextLayout.joinWrapped`).
    private static func joinWrapped(_ head: String, _ tail: String) -> String {
        guard let last = head.last, let first = tail.first else { return head + tail }
        return last.isCJKForWrapping || first.isCJKForWrapping ? head + tail : head + " " + tail
    }

    /// "- ", "* ", "• ", "1. ", "2) ", "3、" — followed by the item's text.
    private static let listMarker = #/^(?:[-*+•·▪◦‣]\s+|\d{1,3}(?:[.)]\s+|、\s*))(?=\S)/#

    /// Greedily packs whole sentences up to `maxCharacters`; a single
    /// sentence longer than that is cut at the limit.
    private static func chunk(_ paragraph: String, maxCharacters: Int) -> [String] {
        guard paragraph.count > maxCharacters else { return [paragraph] }
        var sentences: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = paragraph
        tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
            sentences.append(String(paragraph[range]))
            return true
        }

        var chunks: [String] = []
        var current = ""
        func closeCurrent() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { chunks.append(trimmed) }
            current = ""
        }
        for sentence in sentences {
            if current.count + sentence.count > maxCharacters { closeCurrent() }
            var rest = Substring(sentence)
            while rest.count > maxCharacters {
                current = String(rest.prefix(maxCharacters))
                closeCurrent()
                rest = rest.dropFirst(maxCharacters)
            }
            current += rest
        }
        closeCurrent()
        // `NLTokenizer` finding no sentence at all must not lose the text.
        return chunks.isEmpty ? [paragraph] : chunks
    }
}

private extension Character {
    var isCJKForWrapping: Bool {
        unicodeScalars.contains { (0x3000...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }
}
