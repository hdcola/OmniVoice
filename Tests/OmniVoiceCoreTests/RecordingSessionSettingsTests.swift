import Foundation
import Testing
@testable import OmniVoiceCore

/// Covers `RecordingSession`'s settings-restore self-heal contracts —
/// `restorePersistedSettings()`/`validateAndNormalizeSourceLanguage()`/
/// `transcriptionEngineID`'s `didSet` — so a future engine addition/removal
/// or catalog change can't silently break them. `.serialized` because every
/// test in this suite reads/writes the same process-wide `UserDefaults.standard`
/// domain via `PersistedSettingsKey`.
@MainActor
@Suite(.serialized)
struct RecordingSessionSettingsTests {
    private let defaults = UserDefaults.standard

    private func withPersisted(_ values: [String: Any?], _ body: () -> Void) {
        for (key, value) in values {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defer {
            for key in values.keys {
                defaults.removeObject(forKey: key)
            }
        }
        body()
    }

    @Test func unrecognizedPersistedTranscriptionEngineIDFallsBackToDefault() {
        withPersisted([PersistedSettingsKey.transcriptionEngineID: "bogus.engine.id"]) {
            let session = RecordingSession()
            #expect(session.transcriptionEngineID == ProviderCatalog.transcriptionEngines[0].id)
        }
    }

    @Test func unrecognizedPersistedTranslationEngineIDFallsBackToDefault() {
        withPersisted([PersistedSettingsKey.translationEngineID: "bogus.engine.id"]) {
            let session = RecordingSession()
            #expect(session.translationEngineID == ProviderCatalog.translationEngines[0].id)
        }
    }

    @Test func recognizedPersistedTranscriptionEngineIDIsRestored() {
        withPersisted([PersistedSettingsKey.transcriptionEngineID: "model.r2t2"]) {
            let session = RecordingSession()
            #expect(session.transcriptionEngineID == "model.r2t2")
        }
    }

    @Test func systemEngineWithPersistedUnsupportedSourceLanguageSelfHeals() {
        withPersisted([
            PersistedSettingsKey.transcriptionEngineID: "system.speech",
            PersistedSettingsKey.sourceLanguageCode: "ru-RU",
        ]) {
            let session = RecordingSession()
            #expect(session.transcriptionEngineKind == .system)
            #expect(session.sourceLanguageCode == "en-US")
        }
    }

    @Test func systemEngineWithPersistedAutoSourceLanguageSelfHeals() {
        // "" is sourceLanguageCode's persisted sentinel for nil/"自动".
        withPersisted([
            PersistedSettingsKey.transcriptionEngineID: "system.speech",
            PersistedSettingsKey.sourceLanguageCode: "",
        ]) {
            let session = RecordingSession()
            #expect(session.sourceLanguageCode == "en-US")
        }
    }

    @Test func systemEngineWithPersistedSupportedSourceLanguageIsLeftAlone() {
        withPersisted([
            PersistedSettingsKey.transcriptionEngineID: "system.speech",
            PersistedSettingsKey.sourceLanguageCode: "ja-JP",
        ]) {
            let session = RecordingSession()
            #expect(session.sourceLanguageCode == "ja-JP")
        }
    }

    @Test func modelEngineWithPersistedAutoSourceLanguageIsLeftAlone() {
        withPersisted([
            PersistedSettingsKey.transcriptionEngineID: "model.r2t2",
            PersistedSettingsKey.sourceLanguageCode: "",
        ]) {
            let session = RecordingSession()
            #expect(session.transcriptionEngineKind == .model)
            #expect(session.sourceLanguageCode == nil)
        }
    }

    @Test func switchingBackToSystemEngineSelfHealsAnUnsupportedSourceLanguage() {
        // Not wrapped in withPersisted (no values need restoring up front),
        // but the assignments below still persist via each property's own
        // didSet — clean those back up so later tests in this .serialized
        // suite don't see them as leftover restored state.
        defer {
            defaults.removeObject(forKey: PersistedSettingsKey.transcriptionEngineID)
            defaults.removeObject(forKey: PersistedSettingsKey.sourceLanguageCode)
        }
        let session = RecordingSession()
        session.transcriptionEngineID = "model.r2t2"
        session.sourceLanguageCode = "ru-RU"
        session.transcriptionEngineID = "system.speech"
        #expect(session.sourceLanguageCode == "en-US")
    }

    @Test func includeSystemAudioIsRestoredFromPersistedValue() {
        withPersisted([PersistedSettingsKey.includeSystemAudio: true]) {
            let session = RecordingSession()
            #expect(session.includeSystemAudio)
        }
    }

    @Test func targetLanguageCodeIsRestoredFromPersistedValue() {
        withPersisted([PersistedSettingsKey.targetLanguageCode: "ja-JP"]) {
            let session = RecordingSession()
            #expect(session.targetLanguageCode == "ja-JP")
        }
    }

    @Test func emptyPersistedTargetLanguageCodeIsIgnored() {
        // Guards against a stray/legacy empty string in UserDefaults —
        // unlike sourceLanguageCode, "" was never targetLanguageCode's own
        // sentinel for anything meaningful, so restoring it verbatim would
        // leave targetLanguageCode == "", breaking TranslationSession.
        withPersisted([PersistedSettingsKey.targetLanguageCode: ""]) {
            let session = RecordingSession()
            #expect(session.targetLanguageCode == "zh-CN")
        }
    }

    /// Covers only the "don't lose the preference" half of a disconnected
    /// mic — `refreshDevices()` reads real hardware via
    /// `MicrophoneCapture.availableDevices()`, so this suite can't fabricate
    /// a device becoming available again to also exercise "switches back
    /// once reconnected" without turning that into a dependency-injection
    /// point on `RecordingSession` itself (out of scope here).
    @Test func refreshDevicesFallbackDoesNotClobberPersistedDevicePreference() {
        withPersisted([PersistedSettingsKey.selectedDeviceID: "disconnected-device-id"]) {
            let session = RecordingSession()
            session.refreshDevices()
            #expect(session.selectedDeviceID != "disconnected-device-id")
            #expect(defaults.string(forKey: PersistedSettingsKey.selectedDeviceID) == "disconnected-device-id")
        }
    }

    @Test func isSessionActiveReflectsAnyLifecyclePhase() {
        let session = RecordingSession()
        #expect(!session.isSessionActive)

        session.isStarting = true
        #expect(session.isSessionActive)
        session.isStarting = false
        #expect(!session.isSessionActive)

        session.isRunning = true
        #expect(session.isSessionActive)
        session.isRunning = false
        #expect(!session.isSessionActive)

        session.isStopping = true
        #expect(session.isSessionActive)
        session.isStopping = false
        #expect(!session.isSessionActive)
    }
}
