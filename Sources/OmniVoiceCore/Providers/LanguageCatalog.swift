import Foundation

/// A BCP-47-ish language tag paired with a Chinese display name, for the
/// quick-pick lists in the floating panel/menu bar.
public struct LanguageOption: Identifiable, Hashable, Sendable {
    public let code: String
    public let displayName: String
    public var id: String { code }

    public init(code: String, displayName: String) {
        self.code = code
        self.displayName = displayName
    }
}

/// Single source of truth for the language quick-pick list, shared by
/// `FloatingTranscriptView`'s pickers (source/target) so the two don't drift
/// out of sync with each other.
///
/// This is a curated subset, not an exhaustive list of what `SpeechTranscriber`/
/// `TranslationSession` actually support (which is both larger and
/// runtime-dependent — Apple doesn't expose a stable static list for either
/// framework in a form worth hardcoding here). `SettingsView` keeps an
/// advanced free-text entry for any BCP-47 tag not in this list.
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
        LanguageOption(code: "ru-RU", displayName: "俄语"),
        LanguageOption(code: "ar-SA", displayName: "阿拉伯语"),
        LanguageOption(code: "hi-IN", displayName: "印地语"),
        LanguageOption(code: "vi-VN", displayName: "越南语"),
        LanguageOption(code: "th-TH", displayName: "泰语"),
    ]
}
