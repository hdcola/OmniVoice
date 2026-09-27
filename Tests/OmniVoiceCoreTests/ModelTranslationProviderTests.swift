import Testing
@testable import OmniVoiceCore

/// Covers `ModelTranslationProvider.updateTargetLanguage(_:)` — added so a
/// target-language change made mid-recording actually reaches T3PO (see
/// `RecordingSession.targetLanguageCode`'s `didSet`), not just
/// `SystemTranslationProvider`'s already-working `.translationTask` rebuild.
///
/// Doesn't cover the retargeting actually taking effect in a real
/// translation — that needs T3PO's real (gitignored, not present in CI)
/// GGUF weights loaded via `loadModel()`. This only exercises the call
/// chain down to `InProcessTranslator.setTargetLanguage(_:)`, which is safe
/// to call before any model is loaded (it just queues a `tuning` mutation,
/// with no `model`/`ctx` guard) — so it's meaningful, CI-safe coverage for
/// "doesn't crash on an unloaded provider", just not for "actually
/// retargets".
@MainActor
struct ModelTranslationProviderTests {
    @Test func updateTargetLanguageDoesNotRequireALoadedModel() {
        let provider = ModelTranslationProvider()
        provider.updateTargetLanguage("ja-JP")
        provider.updateTargetLanguage("zh-CN")
    }
}
