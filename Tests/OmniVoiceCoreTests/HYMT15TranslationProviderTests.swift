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
}
