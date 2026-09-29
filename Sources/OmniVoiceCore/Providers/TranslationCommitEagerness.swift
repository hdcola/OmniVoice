import Foundation

/// User-facing control over how eagerly **T3PO** (`model.t3po`) — the only
/// translation engine with a trained WAIT/TRANS decision to bias in the
/// first place — commits a translation for text it's still receiving, vs.
/// waiting for more context first. Maps onto `TranslationLatencyMode`'s
/// `tau` calibration (see `InProcessTranslator`'s class doc and
/// `ModelTranslationProvider`'s mapping).
///
/// A one-shot engine (`HYMT15Translator`, `SystemTranslationProvider`) has
/// no WAIT/TRANS concept, so this setting has no effect there —
/// `TranslationProvider.updateCommitEagerness(_:)`'s default no-op is
/// correct for those, not a placeholder. Those engines instead read
/// `TranslationConfig.earlyTranslateThreshold`/
/// `TranslationProvider.updateEarlyTranslateThreshold(_:)` — see that
/// property's doc for why it's a separate, directly user-configurable
/// number rather than another case of this enum.
///
/// Kept as this app's own small vocabulary, not `TranslationLatencyMode`
/// itself, the same reasoning `ModelLanguageMapping` uses for target
/// language: UI/settings should speak in this app's own terms, with the
/// mapping onto T3PO's own `tau` calibration points hidden behind
/// `ModelTranslationProvider`, not spread across `RecordingSession`/
/// `SettingsView`.
public enum TranslationCommitEagerness: String, CaseIterable, Codable, Sendable {
    case fast, balanced, thorough

    public var displayName: String {
        switch self {
        case .fast: return "更快出结果（可能不够准确）"
        case .balanced: return "标准"
        case .thorough: return "更准确（等待更多上下文）"
        }
    }
}
