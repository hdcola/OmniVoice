import Foundation

/// Maps this app's BCP-47-ish language codes (`LanguageCatalog`) onto R2T2's/
/// T3PO's own small, fixed language option sets — both models only recognize
/// a handful of languages by name, unlike the system frameworks' full BCP-47
/// locales. Matching is by primary language subtag prefix (`"zh"`, `"en"`,
/// `"ja"`, `"ko"`) so regional variants (`zh-TW`, `en-GB`, ...) still map,
/// same as the model's own coarse notion of "a language" rather than "a
/// locale".
enum ModelLanguageMapping {
    /// `nil` (auto-detect) for anything R2T2 has no name for, or for `nil`
    /// itself ("自动" in the picker).
    static func recognitionLanguage(forCode code: String?) -> RecognitionLanguage {
        guard let code else { return .auto }
        return match(code) ?? .auto
    }

    /// Falls back to `.chinese` for anything T3PO has no name for — this
    /// catalog only ever offers `zh`/`en`/`ja`/`ko` as translation targets
    /// (see `LanguageCatalog`), so this should only miss on a future target
    /// language addition that hasn't been taught to T3PO yet.
    static func t3poTargetLanguage(forCode code: String) -> T3POTargetLanguage {
        switch match(code) {
        case .chinese: return .chinese
        case .english: return .english
        case .japanese: return .japanese
        case .korean: return .korean
        case .auto, .none: return .chinese
        }
    }

    /// Same fallback reasoning as `t3poTargetLanguage(forCode:)` — this
    /// catalog only ever offers `zh`/`en`/`ja`/`ko` as translation targets,
    /// a subset of HY-MT1.5's own much larger supported language list.
    static func hyMT15TargetLanguage(forCode code: String) -> HYMT15TargetLanguage {
        switch match(code) {
        case .chinese: return .chinese
        case .english: return .english
        case .japanese: return .japanese
        case .korean: return .korean
        case .auto, .none: return .chinese
        }
    }

    private static func match(_ code: String) -> RecognitionLanguage? {
        let primary = code.split(separator: "-").first.map(String.init)?.lowercased() ?? code.lowercased()
        switch primary {
        case "zh", "yue": return .chinese
        case "en": return .english
        case "ja": return .japanese
        case "ko": return .korean
        default: return nil
        }
    }
}
