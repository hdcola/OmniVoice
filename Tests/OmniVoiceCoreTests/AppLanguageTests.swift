import Foundation
import Testing
@testable import OmniVoiceCore

@Suite("AppLanguage")
struct AppLanguageTests {
    private func freshDefaults() -> (UserDefaults, String) {
        let name = "applanguage-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    @Test func noOverrideMeansFollowSystem() {
        let (defaults, name) = freshDefaults()
        #expect(AppLanguage.stored(defaults: defaults, domain: name) == .system)
    }

    @Test func storeAndReadBack() {
        let (defaults, name) = freshDefaults()
        AppLanguage.store(.simplifiedChinese, defaults: defaults)
        #expect(AppLanguage.stored(defaults: defaults, domain: name) == .simplifiedChinese)
        AppLanguage.store(.english, defaults: defaults)
        #expect(AppLanguage.stored(defaults: defaults, domain: name) == .english)
    }

    @Test func choosingSystemRemovesTheOverride() {
        let (defaults, name) = freshDefaults()
        AppLanguage.store(.english, defaults: defaults)
        AppLanguage.store(.system, defaults: defaults)
        #expect(defaults.persistentDomain(forName: name)?["AppleLanguages"] == nil)
        #expect(AppLanguage.stored(defaults: defaults, domain: name) == .system)
    }

    @Test func unsupportedStoredLanguageReadsAsSystem() {
        let (defaults, name) = freshDefaults()
        defaults.set(["fr"], forKey: "AppleLanguages")
        #expect(AppLanguage.stored(defaults: defaults, domain: name) == .system)
    }

    @Test func systemChoiceResolvesAgainstSystemPreferences() {
        #expect(AppLanguage.system.resolvedCode(systemPreferred: ["zh-Hans-CN", "en-US"]) == "zh-Hans")
        #expect(AppLanguage.system.resolvedCode(systemPreferred: ["en-US"]) == "en")
        #expect(AppLanguage.system.resolvedCode(systemPreferred: ["fr-FR"]) == "en")
        #expect(AppLanguage.english.resolvedCode(systemPreferred: ["zh-Hans-CN"]) == "en")
    }

    @Test func restartIsNeededOnlyWhenTheResolvedLanguageDiffers() {
        #expect(!AppLanguage.needsRestart(stored: .system, running: "zh-Hans", systemPreferred: ["zh-Hans-CN"]))
        #expect(AppLanguage.needsRestart(stored: .english, running: "zh-Hans", systemPreferred: ["zh-Hans-CN"]))
        #expect(!AppLanguage.needsRestart(stored: .english, running: "en", systemPreferred: ["zh-Hans-CN"]))
        #expect(AppLanguage.needsRestart(stored: .system, running: "en", systemPreferred: ["zh-Hans-CN"]))
    }
}
