import Foundation

/// Protects technical entities (URLs, paths, CLI flags, code identifiers)
/// from being translated or distorted by an LLM by replacing them with
/// `⟦0⟧`, `⟦1⟧` placeholders before generation and restoring them afterwards.
public struct EntityMasker: Sendable {
    /// Mask a source string by replacing protected entities with `⟦n⟧` placeholders.
    public static func mask(_ text: String) -> (maskedText: String, verbatim: [String]) {
        guard !text.isEmpty else { return ("", []) }

        var verbatim: [String] = []
        var matches: [(range: Range<String.Index>, text: String)] = []

        // 1. Backticked code spans: `...`
        if let backtickRegex = try? NSRegularExpression(pattern: "`[^`\\n]+`") {
            findMatches(regex: backtickRegex, in: text, into: &matches)
        }

        // 2. URLs: http:// or https://
        if let urlRegex = try? NSRegularExpression(pattern: #"https?://[^\s，。、！？；：”’'\"<>]+"#) {
            findMatches(regex: urlRegex, in: text, into: &matches)
        }

        // 3. File paths: e.g. /usr/local/bin, ./Sources/App.swift
        if let pathRegex = try? NSRegularExpression(pattern: #"(?:\.{1,2}/|/)[a-zA-Z0-9_.-]+(?:/[a-zA-Z0-9_.-]+)+"#) {
            findMatches(regex: pathRegex, in: text, into: &matches)
        }

        // 4. CLI flags: e.g. --verbose, --filter, -c
        if let flagRegex = try? NSRegularExpression(pattern: #"(?<=\s|^)--[a-zA-Z0-9_-]+(?:=[^\s]+)?"#) {
            findMatches(regex: flagRegex, in: text, into: &matches)
        }

        // 5. Code identifiers:
        // - snake_case (e.g. parse_args, model_path)
        // - camelCase / PascalCase (e.g. swiftVersion, OmniVoiceCore)
        // - dotted properties (e.g. config.modelPath, file.swift)
        let words = text.split(omittingEmptySubsequences: true) { char in
            char.isWhitespace || "，。！？；：、“”‘’()[]{}<>".contains(char)
        }

        for word in words {
            let candidate = String(word).trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?\"'"))
            guard candidate.count >= 2 else { continue }
            if isCodeIdentifier(candidate) {
                if let range = text.range(of: candidate) {
                    matches.append((range, candidate))
                }
            }
        }

        // Deduplicate and resolve overlapping ranges (keep the longest span)
        matches.sort { a, b in
            if a.range.lowerBound != b.range.lowerBound {
                return a.range.lowerBound < b.range.lowerBound
            }
            return a.range.upperBound > b.range.upperBound
        }

        var nonOverlapping: [(range: Range<String.Index>, text: String)] = []
        var lastEnd = text.startIndex

        for match in matches {
            if match.range.lowerBound >= lastEnd {
                nonOverlapping.append(match)
                lastEnd = match.range.upperBound
            }
        }

        if nonOverlapping.isEmpty {
            return (text, [])
        }

        var result = ""
        var cursor = text.startIndex

        for (index, match) in nonOverlapping.enumerated() {
            result += text[cursor..<match.range.lowerBound]
            result += "⟦\(index)⟧"
            verbatim.append(match.text)
            cursor = match.range.upperBound
        }
        result += text[cursor...]

        return (result, verbatim)
    }

    /// Restores `⟦n⟧` placeholders in the translation back to their original verbatim values.
    public static func restore(translation: String, verbatim: [String]) -> String {
        guard !verbatim.isEmpty, translation.contains("⟦") else { return translation }

        var result = ""
        var rest = Substring(translation)

        while let open = rest.firstIndex(of: "⟦"), let close = rest[open...].firstIndex(of: "⟧") {
            result += rest[..<open]
            let inner = rest[rest.index(after: open)..<close]
            if let index = Int(inner), verbatim.indices.contains(index) {
                result += verbatim[index]
            } else {
                result += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result
    }

    private static func findMatches(
        regex: NSRegularExpression,
        in text: String,
        into matches: inout [(range: Range<String.Index>, text: String)]
    ) {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let results = regex.matches(in: text, options: [], range: nsRange)
        for result in results {
            if let range = Range(result.range, in: text) {
                matches.append((range, String(text[range])))
            }
        }
    }

    private static func isCodeIdentifier(_ word: String) -> Bool {
        guard word.contains(where: \.isLetter) else { return false }

        // snake_case: e.g. parse_args, model_path
        if word.contains("_"), !word.hasPrefix("_"), !word.hasSuffix("_") {
            return true
        }

        // dotted identifiers: e.g. file.swift, config.target
        let parts = word.split(separator: ".")
        if parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isLetter) }) {
            return true
        }

        // camelCase: lower followed by upper, e.g. parseArgs
        if zip(word, word.dropFirst()).contains(where: { $0.isLowercase && $1.isUppercase }) {
            return true
        }

        return false
    }
}
