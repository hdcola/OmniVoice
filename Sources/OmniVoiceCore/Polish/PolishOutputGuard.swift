import Foundation

/// Checks what the LLM sent back before it is typed into the user's document.
/// Strict on purpose: refusing a good output costs one missed polish, letting
/// a bad one through types the wrong text.
public enum PolishOutputGuard {
    static let minLengthRatio = 0.3
    static let maxLengthRatio = 2.5
    static let maxStructuredLengthRatio = 4.0

    private static let preambles = [
        "好的，", "好的,", "好的：", "好的:", "当然", "没问题", "以下是", "下面是", "整理后", "润色后",
        "输出：", "输出:",
        "here is", "here's", "here are", "sure", "certainly", "of course", "okay,", "ok,",
    ]

    /// The cleaned output, or nil when it should be thrown away.
    ///
    /// - Parameters:
    ///   - output: what the model returned, with `⟦n⟧` placeholders still in.
    ///   - source: the text that was sent (masked), which decides the length
    ///     and which placeholders are expected.
    public static func validate(output: String, source: String, style: PolishStyle) -> String? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        text = strippingWrappingQuotes(text, source: source)
        guard !text.isEmpty else { return nil }
        // A whole-output code block is the model formatting, not polishing
        // (checked after the quotes are gone so quoting can't hide it).
        if text.hasPrefix("```") { return nil }

        let lowered = text.lowercased()
        let sourceLowered = source.lowercased()
        for preamble in preambles where lowered.hasPrefix(preamble) && !sourceLowered.hasPrefix(preamble) {
            return nil
        }
        for marker in PolishPromptBuilder.leakMarkers where text.contains(marker) && !source.contains(marker) {
            return nil
        }

        let sourceLength = source.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard sourceLength > 0 else { return nil }
        let ratio = Double(text.count) / Double(sourceLength)
        let upper = style == .structured ? maxStructuredLengthRatio : maxLengthRatio
        guard ratio >= minLengthRatio, ratio <= upper else { return nil }

        guard placeholders(in: text) == placeholders(in: source) else { return nil }
        return text
    }

    /// The `⟦n⟧` placeholders of `text`, sorted — equal lists mean every one
    /// survived exactly once.
    static func placeholders(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        // Inner whitespace (`⟦ 0 ⟧`) is normalized away: `EntityMasker.restore` handles it.
        return placeholderRegex.matches(in: text, range: range)
            .compactMap { match in
                Range(match.range, in: text).map { String(text[$0]).filter { !$0.isWhitespace } }
            }
            .sorted()
    }

    private static let placeholderRegex = try! NSRegularExpression(pattern: "⟦\\s*\\d+\\s*⟧")

    private static let quotePairs: [(Character, Character)] = [
        ("\"", "\""), ("“", "”"), ("「", "」"), ("『", "』"), ("'", "'"),
    ]

    /// Drops one layer of quotes around the whole output, unless the speaker's
    /// own text was quoted that way.
    private static func strippingWrappingQuotes(_ text: String, source: String) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last,
              quotePairs.contains(where: { $0.0 == first && $0.1 == last })
        else { return text }
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSource.first == first, trimmedSource.last == last { return text }
        return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
