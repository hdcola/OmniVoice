import Foundation
import NaturalLanguage

/// Decides which way a selection is translated — the same two-language
/// rule Cida uses (see its `ModelPromptBuilder`'s `translate_between`):
/// text in the user's own language ("我的语言") goes into their foreign
/// language ("外语"); anything else comes into their own language. So the
/// one shortcut both reads foreign text and drafts replies, without a
/// source/target picker in between.
///
/// Unlike Cida (where the LLM decides from the text itself), neither of
/// this app's local engines can make that call, so the source language is
/// detected up front with `NLLanguageRecognizer`.
public enum SelectionLanguageDirection {
    /// The dominant language of `text` as a BCP-47 tag (`"en"`, `"zh-Hans"`,
    /// ...), or nil when the text is too short/ambiguous to tell.
    /// `myLanguageCode`/`foreignLanguageCode` are passed as hints — the two
    /// languages a user's selections are overwhelmingly in, which is what
    /// keeps a short snippet like "OK, 好" from being detected as some third
    /// language.
    public static func detectLanguageCode(
        of text: String, myLanguageCode: String? = nil, foreignLanguageCode: String? = nil
    ) -> String? {
        // Kana only occurs in Japanese and Hangul only in Korean, however
        // many Han characters surround it — `NLLanguageRecognizer` (nudged
        // further by a Chinese "my language" hint) reads kanji-heavy
        // Japanese as Chinese otherwise.
        if text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return "ja" }
        if text.unicodeScalars.contains(where: { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) }) {
            return "ko"
        }
        let recognizer = NLLanguageRecognizer()
        var hints: [NLLanguage: Double] = [:]
        for code in [myLanguageCode, foreignLanguageCode].compactMap({ $0 }) {
            hints[nlLanguage(forCode: code)] = 0.3
        }
        if !hints.isEmpty { recognizer.languageHints = hints }
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
    }

    /// The target for a selection detected as `detectedCode` — see this
    /// type's doc. Undetected text is assumed foreign (translated into
    /// `myLanguageCode`): reading is the more common case, and translating
    /// "into my language" is the safe direction for text that's actually
    /// already in it (the engine just returns it, near-unchanged).
    public static func targetCode(
        forDetected detectedCode: String?, myLanguageCode: String, foreignLanguageCode: String
    ) -> String {
        guard let detectedCode, isSameLanguage(detectedCode, myLanguageCode) else { return myLanguageCode }
        return foreignLanguageCode
    }

    /// Compares primary language subtags, treating every Chinese variant
    /// (`zh-CN`, `zh-Hant`, `yue-CN`, ...) as one language — a Traditional
    /// Chinese selection for a Simplified Chinese user is "my language" for
    /// direction purposes, same as Cida's `MyLanguageFilter` family rule.
    public static func isSameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        family(of: lhs) == family(of: rhs)
    }

    /// Whether `code`'s language doesn't separate words with spaces —
    /// Chinese and Japanese, the only two of `LanguageCatalog`'s languages
    /// where that's true (see `RecordingSession.appendTranslation(_:)`).
    public static func joinsWithoutSpaces(_ code: String) -> Bool {
        let primary = primarySubtag(of: code)
        return primary == "zh" || primary == "ja" || primary == "yue"
    }

    private static func family(of code: String) -> String {
        let primary = primarySubtag(of: code)
        return primary == "yue" ? "zh" : primary
    }

    private static func primarySubtag(of code: String) -> String {
        code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased() ?? code.lowercased()
    }

    /// `NLLanguage` names Chinese by script (`zh-Hans`/`zh-Hant`), not by
    /// region like `LanguageCatalog` does (`zh-CN`/`zh-TW`).
    private static func nlLanguage(forCode code: String) -> NLLanguage {
        switch code.lowercased() {
        case "zh-tw", "zh-hk", "zh-hant", "yue-cn": return .traditionalChinese
        default: break
        }
        switch family(of: code) {
        case "zh": return .simplifiedChinese
        default: return NLLanguage(rawValue: primarySubtag(of: code))
        }
    }
}
