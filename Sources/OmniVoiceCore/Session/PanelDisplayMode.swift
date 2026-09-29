import Foundation

/// What `FloatingTranscriptView`'s transcript rows show — the proposal's
/// "显示模式切换" (3.1.B): full bilingual pairing by default, or just one
/// side once the other stops being useful (a fully foreign lecture, or a
/// same-language captioning/hearing-assist use case).
public enum PanelDisplayMode: String, CaseIterable, Codable, Sendable {
    case bilingual, translationOnly, sourceOnly

    public var displayName: String {
        switch self {
        case .bilingual: return "双语对照"
        case .translationOnly: return "仅译文"
        case .sourceOnly: return "仅原文"
        }
    }
}

/// Preset font sizes for the floating panel's transcript text (3.1.C) —
/// standard/large/extra-large, matching the proposal's own 14/18/22pt
/// figures for the source line; the translation line stays one point
/// smaller, same ratio the original hardcoded 14pt/13pt pairing used.
public enum PanelFontScale: String, CaseIterable, Codable, Sendable {
    case standard, large, extraLarge

    public var displayName: String {
        switch self {
        case .standard: return "标准"
        case .large: return "大"
        case .extraLarge: return "特大"
        }
    }

    /// `Double`, not `CGFloat` — this type lives in `OmniVoiceCore`, which
    /// (unlike its SwiftUI-side callers) has no CoreGraphics import; callers
    /// wrap this in `CGFloat(...)` at the `.font(.system(size:))` call site.
    public var sourceFontSize: Double {
        switch self {
        case .standard: return 14
        case .large: return 18
        case .extraLarge: return 22
        }
    }

    public var translationFontSize: Double {
        sourceFontSize - 1
    }
}
