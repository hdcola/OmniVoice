import Foundation

/// Maps this app's BCP-47-ish language codes (`LanguageCatalog`) onto R2T2's/
/// T3PO's own small, fixed language option sets — both models only recognize
/// a handful of languages by name, unlike the system frameworks' full BCP-47
/// locales. Matching is by primary language subtag prefix (`"zh"`, `"en"`,
/// `"ja"`, `"ko"`) so regional variants (`zh-TW`, `en-GB`, ...) still map,
/// same as the model's own coarse notion of "a language" rather than "a
/// locale".
public enum ModelLanguageMapping {
    /// `nil` (auto-detect) for anything R2T2 has no name for, or for `nil`
    /// itself ("自动" in the picker).
    static func recognitionLanguage(forCode code: String?) -> RecognitionLanguage {
        guard let code else { return .auto }
        return match(code) ?? .auto
    }

    /// Read-only UI query, deliberately separate from `t3poTargetLanguage(forCode:)`/
    /// `hyMT15TargetLanguage(forCode:)` below — those two keep their existing
    /// silent-fallback-to-Chinese behavior unchanged (see their own docs for
    /// why that's a known gap, not fixed in this pass); this just answers
    /// "would that fallback kick in for `code`", so a settings UI can warn
    /// *before* the user hits it instead of after. `true` for exactly the
    /// same codes `match(_:)` below recognizes (zh/yue/en/ja/ko).
    public static func isNativelyTranslatableByLocalModel(code: String) -> Bool {
        match(code) != nil
    }

    /// Falls back to `.chinese` for anything T3PO has no name for. **Not**
    /// just a future-proofing edge case: `LanguageCatalog.common` already
    /// offers 16 target languages (French/German/Spanish/Russian/... —
    /// `TargetLanguagePicker` doesn't filter by engine), and `match(_:)`
    /// below only recognizes 4 of them — so picking, say, French as the
    /// target while T3PO is the selected translation engine silently
    /// translates into Chinese instead, with no error or warning anywhere.
    /// `SystemTranslationProvider` doesn't have this gap (`Translation`
    /// covers the whole catalog) — this is specific to the two local
    /// models' own small, fixed language sets. Worth a real fix (extending
    /// `T3POTargetLanguage`/`HYMT15TargetLanguage` to cover more of the
    /// catalog where the model actually supports it, or gating the picker
    /// per engine the way `LanguageOption.supportsSystemASRSource` already
    /// gates source language by transcription engine) rather than living
    /// with indefinitely — not done in this pass, see `Docs/PROGRESS.md`.
    static func t3poTargetLanguage(forCode code: String) -> T3POTargetLanguage {
        switch match(code) {
        case .chinese: return .chinese
        case .english: return .english
        case .japanese: return .japanese
        case .korean: return .korean
        case .auto, .none: return .chinese
        }
    }

    /// Same fallback gap as `t3poTargetLanguage(forCode:)`'s doc describes —
    /// only more unfortunate here, since HY-MT1.5's own model card actually
    /// documents official support for French/German/Spanish/... (a good
    /// chunk of what `LanguageCatalog.common` offers) — this mapping just
    /// doesn't expose any of that yet, so those target languages fall back
    /// to Chinese for HY-MT1.5 too even though the underlying model could
    /// likely handle them correctly.
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
