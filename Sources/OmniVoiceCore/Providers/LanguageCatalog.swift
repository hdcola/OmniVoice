import Foundation

/// A BCP-47-ish language tag paired with a Chinese display name, for the
/// quick-pick lists in the floating panel/menu bar.
public struct LanguageOption: Identifiable, Hashable, Sendable {
    public let code: String
    public let displayName: String
    /// False for the handful of languages verified to work as a
    /// `TranslationSession` target but *not* as a `SpeechTranscriber`
    /// source (see `LanguageCatalog`'s doc) — `SourceLanguagePicker` filters
    /// these out while the `.system` transcription engine is selected, since
    /// picking one there throws at `start()` with 100% certainty. Still
    /// offered in the target picker and may become source-capable once
    /// `ModelTranscriptionProvider` lands, hence a flag here rather than two
    /// separate hardcoded lists that would need to stay in sync.
    public let supportsSystemASRSource: Bool
    public var id: String { code }

    public init(code: String, displayName: String, supportsSystemASRSource: Bool = true) {
        self.code = code
        self.displayName = displayName
        self.supportsSystemASRSource = supportsSystemASRSource
    }
}

/// Single source of truth for the language quick-pick list, shared by
/// `FloatingTranscriptView`'s pickers (source/target) so the two don't drift
/// out of sync with each other.
///
/// This is a curated subset, not an exhaustive list of what `SpeechTranscriber`/
/// `TranslationSession` actually support (which is both larger and
/// runtime-dependent — Apple doesn't expose a stable static list for either
/// framework in a form worth hardcoding here).
///
/// **Known source/target asymmetry** (verified against the current system
/// frameworks, macOS 26): `ru-RU`/`ar-SA`/`vi-VN`/`th-TH` all work as a
/// `TranslationSession` *target*, but the system `SpeechTranscriber` does
/// **not** support them as a recognition *source* — picking one as
/// `sourceLanguageCode` with the `.system` transcription engine throws at
/// `start()` with 100% certainty. `SourceLanguagePicker` filters these out
/// via `LanguageOption.supportsSystemASRSource` while `.system` is selected;
/// they still appear in `TargetLanguagePicker`. Once `ModelTranscriptionProvider`
/// (R2T2) lands, its locale support may differ and could lift this
/// restriction for that engine.
public enum LanguageCatalog {
    public static let common: [LanguageOption] = [
        LanguageOption(code: "zh-CN", displayName: "简体中文"),
        LanguageOption(code: "zh-TW", displayName: "繁体中文"),
        LanguageOption(code: "yue-CN", displayName: "粤语"),
        LanguageOption(code: "en-US", displayName: "英语"),
        LanguageOption(code: "ja-JP", displayName: "日语"),
        LanguageOption(code: "ko-KR", displayName: "韩语"),
        LanguageOption(code: "fr-FR", displayName: "法语"),
        LanguageOption(code: "de-DE", displayName: "德语"),
        LanguageOption(code: "es-ES", displayName: "西班牙语"),
        LanguageOption(code: "it-IT", displayName: "意大利语"),
        LanguageOption(code: "pt-PT", displayName: "葡萄牙语"),
        LanguageOption(code: "hi-IN", displayName: "印地语"),
        // Verified target-only for the system engines — see this enum's doc.
        LanguageOption(code: "ru-RU", displayName: "俄语", supportsSystemASRSource: false),
        LanguageOption(code: "ar-SA", displayName: "阿拉伯语", supportsSystemASRSource: false),
        LanguageOption(code: "vi-VN", displayName: "越南语", supportsSystemASRSource: false),
        LanguageOption(code: "th-TH", displayName: "泰语", supportsSystemASRSource: false),
    ]

    /// The Chinese display name for `code`, or `code` itself for a custom
    /// locale outside `common`.
    public static func displayName(for code: String) -> String {
        common.first { $0.code == code }?.displayName ?? code
    }

    /// Like `displayName(for:)`, but also names the tags `NLLanguageRecognizer`
    /// produces — `en`, `zh-Hant`, `nl`, ... — instead of echoing them back:
    /// the catalog's name when it lists the language, else the system's
    /// Chinese name for it.
    public static func localizedName(for code: String) -> String {
        if let exact = common.first(where: { $0.code == code }) {
            return exact.displayName
        }
        // NaturalLanguage names Chinese by script (`zh-Hant`), the catalog
        // by region (`zh-TW`).
        if code.lowercased().hasSuffix("hant") {
            return "繁体中文"
        }
        // Cantonese counts as Chinese for `isSameLanguage`, but has a
        // catalog entry of its own.
        if code.lowercased().hasPrefix("yue") {
            return displayName(for: "yue-CN")
        }
        if let sameLanguage = common.first(where: { SelectionLanguageDirection.isSameLanguage($0.code, code) }) {
            return sameLanguage.displayName
        }
        return Locale(identifier: "zh-Hans").localizedString(forIdentifier: code) ?? code
    }
}
