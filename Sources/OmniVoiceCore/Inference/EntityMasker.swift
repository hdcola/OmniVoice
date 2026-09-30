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
        findMatches(regex: backtickRegex, in: text, into: &matches)

        // 2. URLs: http:// or https://
        findMatches(regex: urlRegex, in: text, into: &matches, trimTrailingPunctuation: true)

        // 3. File paths: e.g. /usr/local/bin, ./Sources/App.swift, ~/Downloads
        // The lookbehind keeps it from starting mid-word, so `and/or/xor` or
        // `1/2/3` in ordinary speech aren't masked. `~/`, `./`, `../` are
        // unambiguous path markers so a single segment (`~/Downloads`) is
        // enough; a bare `/` still requires two segments to avoid masking
        // something like "a/b" in ordinary prose.
        findMatches(regex: pathRegex, in: text, into: &matches, trimTrailingPunctuation: true)

        // 4. CLI flags: e.g. --verbose, --filter=x, -c, -h, -rf, -czvf, -Wall.
        // Matched even with no preceding space — common in space-less ASR
        // transcripts of CJK speech (e.g. "执行--dry-run选项") — but a short
        // flag's body is letters-only, so a negative number like -1 or -3.14
        // is never masked.
        findMatches(regex: flagRegex, in: text, into: &matches, trimTrailingPunctuation: true)

        // 5. Code identifiers:
        // - snake_case / dunder (e.g. parse_args, model_path, MAX_BUFFER_SIZE,
        //   _private_var, __init__)
        findMatches(regex: snakeRegex, in: text, into: &matches)

        // - filenames with a known extension (e.g. file.swift, README.md)
        // - dotted member access that looks like code (e.g. config.modelPath,
        //   self.view.frame)
        // Deliberately narrow: ordinary prose like `e.g`, `U.S`, `Mr.Smith`
        // or ASR output missing a space (`okay.So`) must stay translatable.
        findMatches(regex: fileRegex, in: text, into: &matches)
        findMatches(regex: dottedRegex, in: text, into: &matches)

        // - camelCase / PascalCase (e.g. swiftVersion, OmniVoiceCore)
        findMatches(regex: camelRegex, in: text, into: &matches)

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

    // MARK: - Precompiled patterns
    //
    // `NSRegularExpression` is documented immutable/thread-safe once built, so
    // these compile once at first use instead of once per `mask(_:)`/
    // `restore(translation:verbatim:)` call — both run on every ASR delta and
    // inside `HYMT15Translator`'s budget-trimming retry loop, so this is a hot
    // path. Every pattern here is a fixed literal known to compile, so `try!`
    // is a deliberate load-time assertion, not a runtime possibility.
    private static let backtickRegex = try! NSRegularExpression(pattern: "`[^`\\n]+`")
    private static let urlRegex = try! NSRegularExpression(pattern: #"https?://[^\s，。、！？；：”’'\"<>]+"#)
    private static let pathRegex = try! NSRegularExpression(
        pattern: #"(?<![a-zA-Z0-9_.~/-])(?:(?:~/|\.{1,2}/)[a-zA-Z0-9_.-]+(?:/[a-zA-Z0-9_.-]+)*|/[a-zA-Z0-9_.-]+(?:/[a-zA-Z0-9_.-]+)+)"#
    )
    // `-[a-zA-Z]+` (one or more *letters*) also covers combined short flags
    // like `-rf`, `-czvf`, `-Wall` — it still can't match a negative number
    // (`-1`, `-3.14`) since digits aren't letters. The `=value` part is
    // restricted to common CLI-value characters (or a quoted string) rather
    // than "any non-whitespace" — CJK ASR transcripts have no space after a
    // flag's value, so `--output=foo选项` would otherwise swallow "选项"
    // into the masked entity too. `:` is included so a value that's itself a
    // URL or host:port (`--url=https://...`, `--addr=127.0.0.1:8080`) is
    // captured whole — otherwise it'd split at "https", leaving the
    // unmasked, untranslated "://..." remainder behind (the url/path
    // patterns run earlier but lose to this narrower, earlier-starting
    // match once overlap resolution keeps whichever sorts first).
    private static let flagRegex = try! NSRegularExpression(
        pattern: #"(?<![a-zA-Z0-9_-])(?:--[a-zA-Z0-9_-]+(?:="# + flagValue + #")?|-[a-zA-Z]+(?:="# + flagValue + #")?)(?![a-zA-Z0-9_-])"#
    )
    private static let flagValue = #"(?:"[^"]+"|'[^']+'|[a-zA-Z0-9_.~/:-]+)"#
    private static let snakeRegex = try! NSRegularExpression(
        pattern: #"(?<![a-zA-Z0-9_])(?:__[a-zA-Z][a-zA-Z0-9]*__|_*[a-zA-Z][a-zA-Z0-9]*(?:_+[a-zA-Z0-9]+)+_*)(?![a-zA-Z0-9_])"#
    )
    // The basename requires at least 2 characters (`[a-zA-Z_][a-zA-Z0-9_-]+`,
    // not `*`): `fileExtensions` includes single-letter extensions like `m`
    // and `h` for Objective-C, and a `*` there would let "10 a.m." or
    // "8 p.m." match as a filename with basename "a"/"p".
    private static let fileRegex: NSRegularExpression = {
        let extensions = fileExtensions.joined(separator: "|")
        return try! NSRegularExpression(
            pattern: #"(?<![a-zA-Z0-9_.])[a-zA-Z_][a-zA-Z0-9_-]+\.(?:"# + extensions + #")(?![a-zA-Z0-9_])"#
        )
    }()
    private static let dottedRegex: NSRegularExpression = {
        let member = #"[a-z_][a-zA-Z0-9_]*"#
        let codeMember = #"[a-z_][a-zA-Z0-9_]*(?:[A-Z0-9_])[a-zA-Z0-9_]*"#
        return try! NSRegularExpression(
            pattern: #"(?<![a-zA-Z0-9_.])[a-zA-Z_][a-zA-Z0-9_]+(?:\."# + codeMember + #"|(?:\."# + member + #"){2,})(?![a-zA-Z0-9_]|\.[a-zA-Z])"#
        )
    }()
    private static let camelRegex = try! NSRegularExpression(
        pattern: #"(?<![a-zA-Z0-9])[a-zA-Z0-9]*[a-z][A-Z][a-zA-Z0-9]*(?![a-zA-Z0-9])"#
    )
    private static let placeholderRegex = try! NSRegularExpression(
        pattern: #"⟦\s*([0-9]+)\s*⟧|⟦\s*([0-9]+)|([0-9]+)\s*⟧"#
    )
    /// ASCII punctuation that's almost always sentence/clause punctuation
    /// rather than part of the entity itself when it trails a URL or path
    /// match — e.g. "visit https://example.com." shouldn't mask the period.
    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?"]
    /// Closing brackets that trail a URL/path match only because the whole
    /// entity sat inside a parenthetical (e.g. "(https://github.com)") — but
    /// not when the bracket is itself part of the entity (e.g. a Wikipedia
    /// URL like ".../wiki/Foo_(bar)", where opens and closes balance).
    private static let trailingCloserToOpener: [Character: Character] = [
        ")": "(", "]": "[", "）": "（", "】": "【",
    ]

    private static func findMatches(
        regex: NSRegularExpression,
        in text: String,
        into matches: inout [(range: Range<String.Index>, text: String)],
        trimTrailingPunctuation: Bool = false
    ) {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let results = regex.matches(in: text, options: [], range: nsRange)
        for result in results {
            guard var range = Range(result.range, in: text) else { continue }
            if trimTrailingPunctuation {
                trimLoop: while range.upperBound > range.lowerBound {
                    let last = text[text.index(before: range.upperBound)]
                    if trailingPunctuation.contains(last) {
                        range = range.lowerBound..<text.index(before: range.upperBound)
                        continue
                    }
                    if let opener = trailingCloserToOpener[last] {
                        let opens = text[range].filter { $0 == opener }.count
                        let closes = text[range].filter { $0 == last }.count
                        if closes > opens {
                            range = range.lowerBound..<text.index(before: range.upperBound)
                            continue
                        }
                    }
                    break trimLoop
                }
                guard !range.isEmpty else { continue }
            }
            matches.append((range, String(text[range])))
        }
    }
}
