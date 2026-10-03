import Foundation

/// One installed system voice, reduced to what picking needs — keeps the
/// choice testable without AVFoundation (the app maps `AVSpeechSynthesisVoice`
/// onto this).
public struct SpeechVoiceCandidate: Equatable, Sendable {
    public let identifier: String
    /// BCP-47 tag of the voice, e.g. `zh-CN`.
    public let language: String
    /// Higher is better: default < enhanced < premium.
    public let quality: Int

    public init(identifier: String, language: String, quality: Int) {
        self.identifier = identifier
        self.language = language
        self.quality = quality
    }
}

/// Maps the language tags the translation panel carries (`LanguageCatalog`
/// codes like `zh-CN`, `NLLanguageRecognizer` tags like `zh-Hant`, or a bare
/// `en`) onto the installed system voice that should read them.
public enum SpeechVoiceResolver {
    /// The tag speech voices use for `code`: Chinese by region (`zh-Hans` →
    /// `zh-CN`, `zh-Hant` → `zh-TW`), Cantonese as `yue-HK` (what the system's
    /// Cantonese voice reports), and a bare language gets its usual region.
    public static func speechLanguageCode(for code: String) -> String {
        let normalized = code.replacingOccurrences(of: "_", with: "-")
        let parts = normalized.split(separator: "-").map(String.init)
        guard let primary = parts.first?.lowercased() else { return code }
        let rest = Set(parts.dropFirst().map { $0.lowercased() })

        switch primary {
        case "yue": return "yue-HK"
        case "zh":
            if rest.contains("hk") { return "yue-HK" }
            if rest.contains("hant") || rest.contains("tw") { return "zh-TW" }
            return "zh-CN"
        default: break
        }
        // Already region-qualified (`en-GB`, `pt-BR`): keep it.
        if let region = parts.dropFirst().first(where: { $0.count == 2 }) {
            return "\(primary)-\(region.uppercased())"
        }
        return defaultRegions[primary].map { "\(primary)-\($0)" } ?? primary
    }

    /// The best installed voice for `code`: an exact language match wins,
    /// then any voice of the same language (a `zh-TW` request with only
    /// `zh-CN` voices installed still reads Chinese); within a tier the
    /// highest quality, first listed on a tie. Nil when the language has no
    /// voice at all.
    public static func bestVoice(for code: String, among voices: [SpeechVoiceCandidate]) -> SpeechVoiceCandidate? {
        let wanted = speechLanguageCode(for: code)
        let exact = voices.filter { tag($0.language) == tag(wanted) }
        let sameLanguage = voices.filter { primary($0.language) == primary(wanted) }
        for tier in [exact, sameLanguage] {
            if let best = tier.reduce(nil as SpeechVoiceCandidate?, { best, voice in
                guard let best else { return voice }
                return voice.quality > best.quality ? voice : best
            }) {
                return best
            }
        }
        return nil
    }

    private static let defaultRegions: [String: String] = [
        "en": "US", "ja": "JP", "ko": "KR", "fr": "FR", "de": "DE", "es": "ES", "it": "IT",
        "pt": "PT", "hi": "IN", "ru": "RU", "ar": "SA", "vi": "VN", "th": "TH",
    ]

    /// Lowercased, with the older `zh-HK` spelling of Cantonese folded into
    /// `yue-HK` so a voice reporting either one matches either request.
    private static func tag(_ code: String) -> String {
        let tag = code.replacingOccurrences(of: "_", with: "-").lowercased()
        return tag == "zh-hk" ? "yue-hk" : tag
    }

    private static func primary(_ code: String) -> String {
        tag(code).split(separator: "-").first.map(String.init) ?? tag(code)
    }
}
