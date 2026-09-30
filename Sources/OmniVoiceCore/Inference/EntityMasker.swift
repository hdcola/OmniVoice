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

        // 3. File paths: e.g. /usr/local/bin, ./Sources/App.swift, ~/Downloads/x
        // The lookbehind keeps it from starting mid-word, so `and/or/xor` or
        // `1/2/3` in ordinary speech aren't masked.
        if let pathRegex = try? NSRegularExpression(pattern: #"(?<![a-zA-Z0-9_.~/-])(?:~/|\.{1,2}/|/)[a-zA-Z0-9_.-]+(?:/[a-zA-Z0-9_.-]+)+"#) {
            findMatches(regex: pathRegex, in: text, into: &matches)
        }

        // 4. CLI flags: e.g. --verbose, --filter, -c
        if let flagRegex = try? NSRegularExpression(pattern: #"(?<=\s|^)--[a-zA-Z0-9_-]+(?:=[^\s]+)?"#) {
            findMatches(regex: flagRegex, in: text, into: &matches)
        }

        // 5. Code identifiers:
        // - snake_case (e.g. parse_args, model_path, MAX_BUFFER_SIZE, _private_var)
        if let snakeRegex = try? NSRegularExpression(pattern: #"(?<![a-zA-Z0-9_])_*[a-zA-Z][a-zA-Z0-9]*(?:_+[a-zA-Z0-9]+)+_*(?![a-zA-Z0-9_])"#) {
            findMatches(regex: snakeRegex, in: text, into: &matches)
        }

        // - filenames with a known extension (e.g. file.swift, README.md)
        // - dotted member access that looks like code (e.g. config.modelPath,
        //   self.view.frame)
        // Deliberately narrow: ordinary prose like `e.g`, `U.S`, `Mr.Smith`
        // or ASR output missing a space (`okay.So`) must stay translatable.
        let extensions = Self.fileExtensions.joined(separator: "|")
        if let fileRegex = try? NSRegularExpression(pattern: #"(?<![a-zA-Z0-9_.])[a-zA-Z_][a-zA-Z0-9_-]*\.(?:"# + extensions + #")(?![a-zA-Z0-9_])"#) {
            findMatches(regex: fileRegex, in: text, into: &matches)
        }
        let member = #"[a-z_][a-zA-Z0-9_]*"#
        let codeMember = #"[a-z_][a-zA-Z0-9_]*(?:[A-Z0-9_])[a-zA-Z0-9_]*"#
        if let dottedRegex = try? NSRegularExpression(pattern:
            #"(?<![a-zA-Z0-9_.])[a-zA-Z_][a-zA-Z0-9_]+(?:\."# + codeMember + #"|(?:\."# + member + #"){2,})(?![a-zA-Z0-9_]|\.[a-zA-Z])"#
        ) {
            findMatches(regex: dottedRegex, in: text, into: &matches)
        }

        // - camelCase / PascalCase (e.g. swiftVersion, OmniVoiceCore)
        if let camelRegex = try? NSRegularExpression(pattern: #"(?<![a-zA-Z0-9])[a-zA-Z0-9]*[a-z][A-Z][a-zA-Z0-9]*(?![a-zA-Z0-9])"#) {
            findMatches(regex: camelRegex, in: text, into: &matches)
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
    /// Tolerates what a small model tends to do to them — inner whitespace
    /// (`⟦ 0 ⟧`) or a lost bracket (`0⟧`, `⟦0`) — and drops numbered
    /// placeholders that don't exist, rather than leaving a bare number where
    /// an entity should be. Any remaining stray brackets are removed.
    public static func restore(translation: String, verbatim: [String]) -> String {
        guard translation.contains("⟦") || translation.contains("⟧") else { return translation }

        var result = translation
        if let placeholderRegex = try? NSRegularExpression(pattern: #"⟦\s*([0-9]+)\s*⟧|⟦\s*([0-9]+)|([0-9]+)\s*⟧"#) {
            let nsRange = NSRange(translation.startIndex..<translation.endIndex, in: translation)
            // Replace back to front so earlier ranges stay valid.
            for match in placeholderRegex.matches(in: translation, range: nsRange).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let digits = (1...3).lazy
                    .map { match.range(at: $0) }
                    .first { $0.location != NSNotFound }
                    .flatMap { Range($0, in: translation) }
                    .map { String(translation[$0]) }
                let isFullPlaceholder = match.range(at: 1).location != NSNotFound
                if let digits, let index = Int(digits), verbatim.indices.contains(index) {
                    result.replaceSubrange(range, with: verbatim[index])
                } else if isFullPlaceholder {
                    // Also swallow one following space when the placeholder
                    // sits between spaces, so no double space is left behind.
                    var removal = range
                    if removal.upperBound < result.endIndex, result[removal.upperBound] == " ",
                       removal.lowerBound == result.startIndex || result[result.index(before: removal.lowerBound)].isWhitespace
                    {
                        removal = removal.lowerBound..<result.index(after: removal.upperBound)
                    }
                    result.removeSubrange(removal)
                }
                // A half-bracketed number that isn't a valid index is most
                // likely real text; its stray bracket is removed below.
            }
        }

        if result.contains("⟦") || result.contains("⟧") {
            result = result.replacingOccurrences(of: "⟦", with: "")
            result = result.replacingOccurrences(of: "⟧", with: "")
        }
        return result
    }

    private static let fileExtensions = [
        "swift", "py", "js", "mjs", "ts", "tsx", "jsx", "json", "md", "txt", "yml", "yaml", "toml",
        "plist", "sh", "zsh", "bash", "c", "h", "m", "mm", "cc", "cpp", "hpp", "rs", "go", "java",
        "kt", "rb", "php", "html", "css", "scss", "xml", "gguf", "bin", "log", "csv", "sql", "db",
        "png", "jpg", "jpeg", "gif", "svg", "pdf", "zip", "gz", "tar", "dmg", "pkg", "app",
        "lock", "cfg", "ini", "env", "conf", "xcodeproj", "xcworkspace", "entitlements", "strings",
    ]

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
}
