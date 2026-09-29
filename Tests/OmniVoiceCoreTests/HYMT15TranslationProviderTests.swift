import Testing
@testable import OmniVoiceCore

/// Mirrors `ModelTranslationProviderTests` — see its doc for why this only
/// exercises "doesn't crash on an unloaded provider", not an actual
/// translation (which needs HY-MT1.5's real, gitignored GGUF weights).
@MainActor
struct HYMT15TranslationProviderTests {
    @Test func updateTargetLanguageDoesNotRequireALoadedModel() {
        let provider = HYMT15TranslationProvider()
        provider.updateTargetLanguage("ja-JP")
        provider.updateTargetLanguage("zh-CN")
    }

    /// `feed(_:)`'s `earlyTranslateThreshold` length check (see
    /// `HYMT15Translator.feed(sourceDelta:)`'s doc) reads `model`/`ctx`
    /// first and no-ops without them loaded — this exercises that no-op
    /// path is actually safe to call, not just the pre-existing "reject
    /// empty deltas" no-op.
    @Test func feedAndEarlyTranslateThresholdChangesDoNotRequireALoadedModel() {
        let provider = HYMT15TranslationProvider()
        provider.updateEarlyTranslateThreshold(60)
        provider.feed(String(repeating: "x", count: 60))
        provider.flush()
    }
}
