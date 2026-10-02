import Foundation
import Testing
@testable import OmniVoiceCore

struct LanguageSettingsMigrationTests {
    private func legacy(
        source: String? = "en-US", target: String = "zh-CN",
        quickMine: String? = nil, quickForeign: String? = nil, model: Bool = false
    ) -> LegacyLanguageSettings {
        LegacyLanguageSettings(
            source: source, target: target, quickMine: quickMine, quickForeign: quickForeign, isModelEngine: model
        )
    }

    @Test func defaultsBecomeChineseAndEnglishListeningToForeign() {
        let result = LanguageSettingsMigration.migrate(legacy())
        #expect(result.mine == "zh-CN")
        #expect(result.foreign == "en-US")
        #expect(result.direction == .listenForeign)
        #expect(!result.foreignAutoDetect)
        // Voice input used to follow the source language.
        #expect(result.dictation == .foreign)
    }

    @Test func recordingLanguagesAreInferredWhenQuickTranslateWasNeverCustomized() {
        let result = LanguageSettingsMigration.migrate(legacy(source: "ja-JP", target: "en-US"))
        #expect(result.mine == "en-US")
        #expect(result.foreign == "ja-JP")
        #expect(result.direction == .listenForeign)
    }

    @Test func customizedQuickTranslateLanguagesWin() {
        let result = LanguageSettingsMigration.migrate(
            legacy(source: "ja-JP", target: "fr-FR", quickMine: "zh-TW", quickForeign: "ko-KR")
        )
        #expect(result.mine == "zh-TW")
        #expect(result.foreign == "ko-KR")
        #expect(result.direction == .listenForeign)
    }

    @Test func sourceInMyLanguageMeansSpeaking() {
        let result = LanguageSettingsMigration.migrate(
            legacy(source: "zh-CN", target: "en-US", quickMine: "zh-CN", quickForeign: "ja-JP")
        )
        #expect(result.direction == .speakMine)
        #expect(result.dictation == .mine)
    }

    @Test func autoSourceKeepsAutoDetectAndPicksDictationByEngine() {
        let onModel = LanguageSettingsMigration.migrate(legacy(source: nil, model: true))
        #expect(onModel.foreignAutoDetect)
        #expect(onModel.dictation == .auto)
        let onSystem = LanguageSettingsMigration.migrate(legacy(source: nil, model: false))
        #expect(onSystem.foreignAutoDetect)
        #expect(onSystem.dictation == .mine)
    }

    @Test func sameLanguageSourceAndTargetStillYieldTwoDistinctLanguages() {
        let result = LanguageSettingsMigration.migrate(legacy(source: "zh-TW", target: "zh-CN"))
        #expect(!SelectionLanguageDirection.isSameLanguage(result.mine, result.foreign))
        let english = LanguageSettingsMigration.migrate(legacy(source: nil, target: "en-US"))
        #expect(!SelectionLanguageDirection.isSameLanguage(english.mine, english.foreign))
    }
}

@MainActor
struct LanguagePreferencesTests {
    private static func makeDefaults() -> UserDefaults {
        let suite = "LanguagePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func freshInstallDefaults() {
        let languages = LanguagePreferences(defaults: Self.makeDefaults())
        #expect(languages.sourceLanguageCode == "en-US")
        #expect(languages.targetLanguageCode == "zh-CN")
    }

    @Test func migratesOldKeysOnceAndLeavesThemInPlace() {
        let defaults = Self.makeDefaults()
        defaults.set("ja-JP", forKey: PersistedSettingsKey.sourceLanguageCode)
        defaults.set("en-US", forKey: PersistedSettingsKey.targetLanguageCode)
        let first = LanguagePreferences(defaults: defaults)
        #expect(first.foreignLanguageCode == "ja-JP")
        #expect(first.myLanguageCode == "en-US")
        #expect(defaults.string(forKey: PersistedSettingsKey.sourceLanguageCode) == "ja-JP")

        // A later change to the old keys must not re-run the migration.
        defaults.set("ko-KR", forKey: PersistedSettingsKey.sourceLanguageCode)
        let second = LanguagePreferences(defaults: defaults)
        #expect(second.foreignLanguageCode == "ja-JP")
    }

    @Test func changesPersist() {
        let defaults = Self.makeDefaults()
        let languages = LanguagePreferences(defaults: defaults)
        languages.foreignLanguageCode = "fr-FR"
        languages.swapDirection()
        let reloaded = LanguagePreferences(defaults: defaults)
        #expect(reloaded.foreignLanguageCode == "fr-FR")
        #expect(reloaded.transcriptionDirection == .speakMine)
    }

    @Test func swapExchangesSourceAndTarget() {
        let languages = LanguagePreferences(defaults: Self.makeDefaults())
        languages.swapDirection()
        #expect(languages.sourceLanguageCode == "zh-CN")
        #expect(languages.targetLanguageCode == "en-US")
        languages.swapDirection()
        #expect(languages.sourceLanguageCode == "en-US")
        #expect(languages.targetLanguageCode == "zh-CN")
    }

    @Test func swapIsRefusedWhileSourceIsAuto() {
        let languages = LanguagePreferences(defaults: Self.makeDefaults())
        languages.sourceLanguageCode = nil
        #expect(!languages.canSwapDirection)
        languages.swapDirection()
        #expect(languages.transcriptionDirection == .listenForeign)
    }

    @Test func settingSourceAndTargetWritesTheMatchingLanguage() {
        let languages = LanguagePreferences(defaults: Self.makeDefaults())
        languages.sourceLanguageCode = "ja-JP"
        languages.targetLanguageCode = "zh-TW"
        #expect(languages.foreignLanguageCode == "ja-JP")
        #expect(languages.myLanguageCode == "zh-TW")
        languages.swapDirection()
        languages.sourceLanguageCode = "ko-KR"
        languages.targetLanguageCode = "fr-FR"
        #expect(languages.myLanguageCode == "ko-KR")
        #expect(languages.foreignLanguageCode == "fr-FR")
    }

    @Test func dictationLanguageResolution() {
        typealias Session = RecordingSession
        #expect(Session.resolveDictationLanguage(choice: .mine, mine: "zh-CN", foreign: "en-US", isModelEngine: false) == "zh-CN")
        #expect(Session.resolveDictationLanguage(choice: .foreign, mine: "zh-CN", foreign: "en-US", isModelEngine: true) == "en-US")
        #expect(Session.resolveDictationLanguage(choice: .auto, mine: "zh-CN", foreign: "en-US", isModelEngine: true) == nil)
        #expect(Session.resolveDictationLanguage(choice: .auto, mine: "zh-CN", foreign: "en-US", isModelEngine: false) == "zh-CN")
        // Russian isn't a system-recognizer source language.
        #expect(Session.resolveDictationLanguage(choice: .foreign, mine: "zh-CN", foreign: "ru-RU", isModelEngine: false) == nil)
    }
}
