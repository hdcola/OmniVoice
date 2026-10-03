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

    /// The unified language keys (and the schema version that gates the
    /// migration from the old source/target keys) — cleared around every
    /// test so the old keys a test seeds are actually migrated.
    private static let languageKeys = [
        PersistedLanguageKey.schemaVersion, PersistedLanguageKey.myLanguageCode,
        PersistedLanguageKey.foreignLanguageCode, PersistedLanguageKey.transcriptionDirection,
        PersistedLanguageKey.foreignLanguageAutoDetect, PersistedLanguageKey.dictationLanguage,
    ]

    private func withPersisted(_ values: [String: Any?], _ body: () -> Void) {
        for key in Self.languageKeys { defaults.removeObject(forKey: key) }
        defer { for key in Self.languageKeys { defaults.removeObject(forKey: key) } }
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

    /// A `ModelDownloadManager` whose cache directory already contains
    /// `variant`'s weights (an empty stand-in file — nothing here ever reads
    /// its contents) — for exercising "a `.model` engine that's actually
    /// downloaded" without a real network transfer. Plain `RecordingSession()`
    /// uses `.shared`, which reads the real Application Support directory —
    /// empty in this test environment, so `fallBackToSystemEngineIfModelUnavailable()`
    /// would otherwise always revert these tests' `.model` selections back to
    /// `.system` before they get to assert anything about them.
    private func makeDownloadManager(withDownloaded variant: ModelVariant) throws -> ModelDownloadManager {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingSessionSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let manager = ModelDownloadManager(cacheDirectory: cacheDirectory)
        FileManager.default.createFile(atPath: manager.localURL(for: variant).path, contents: Data())
        return manager
    }

    /// A fresh, empty cache directory — for exercising "nothing downloaded
    /// yet" against an isolated `ModelDownloadManager` rather than `.shared`'s
    /// real (also-empty-in-tests, but shared/mutable) Application Support
    /// directory.
    private func makeEmptyTempCacheDirectory() -> URL {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingSessionSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        return cacheDirectory
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

    @Test func recognizedPersistedTranscriptionEngineIDIsRestored() throws {
        let variant = try #require(ProviderCatalog.modelVariants(forEngineID: "model.r2t2").first)
        let manager = try makeDownloadManager(withDownloaded: variant)
        withPersisted([PersistedSettingsKey.transcriptionEngineID: "model.r2t2"]) {
            let session = RecordingSession(modelDownloadManager: manager)
            #expect(session.transcriptionEngineID == "model.r2t2")
        }
    }

    /// Complements the above — restoring a persisted `.model` engine with
    /// *nothing* downloaded for it (a fresh install, or a variant deleted via
    /// "模型管理" since the last launch) must fall back to the `.system`
    /// counterpart rather than leaving the selection pointing at a model
    /// `start()`/`preloadModel()` can't use.
    @Test func recognizedPersistedTranscriptionEngineIDWithNothingDownloadedFallsBackToSystem() {
        withPersisted([PersistedSettingsKey.transcriptionEngineID: "model.r2t2"]) {
            let session = RecordingSession(modelDownloadManager: ModelDownloadManager(cacheDirectory: makeEmptyTempCacheDirectory()))
            #expect(session.transcriptionEngineID == "system.speech")
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

    @Test func modelEngineWithPersistedAutoSourceLanguageIsLeftAlone() throws {
        let variant = try #require(ProviderCatalog.modelVariants(forEngineID: "model.r2t2").first)
        let manager = try makeDownloadManager(withDownloaded: variant)
        withPersisted([
            PersistedSettingsKey.transcriptionEngineID: "model.r2t2",
            PersistedSettingsKey.sourceLanguageCode: "",
        ]) {
            let session = RecordingSession(modelDownloadManager: manager)
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
            for key in Self.languageKeys { defaults.removeObject(forKey: key) }
        }
        for key in Self.languageKeys { defaults.removeObject(forKey: key) }
        let session = RecordingSession()
        session.transcriptionEngineID = "model.r2t2"
        session.sourceLanguageCode = "ru-RU"
        session.transcriptionEngineID = "system.speech"
        #expect(session.sourceLanguageCode == "en-US")
    }

    @Test func selfHealKeepsMyAndForeignLanguagesDistinct() {
        withPersisted([
            PersistedSettingsKey.transcriptionEngineID: "system.speech",
            PersistedSettingsKey.sourceLanguageCode: "ru-RU",
            PersistedSettingsKey.targetLanguageCode: "en-US",
        ]) {
            let session = RecordingSession()
            #expect(session.languages.myLanguageCode == "en-US")
            #expect(session.languages.foreignLanguageCode == "zh-CN")
            #expect(session.sourceLanguageCode == "zh-CN")
        }
    }

    @Test func swapIsRefusedWhenTheSystemRecognizerCannotHearTheOtherSide() {
        withPersisted([
            PersistedSettingsKey.transcriptionEngineID: "system.speech",
            PersistedSettingsKey.sourceLanguageCode: "en-US",
            PersistedSettingsKey.targetLanguageCode: "ru-RU",
        ]) {
            let session = RecordingSession()
            #expect(session.languages.myLanguageCode == "ru-RU")
            #expect(session.sourceLanguageCode == "en-US")
            #expect(!session.canSwapTranscriptionDirection)
            #expect(session.swapBlockedReason == "系统语音识别不支持互换后的源语言")
            session.swapTranscriptionDirection()
            #expect(session.sourceLanguageCode == "en-US")
        }
    }

    @Test func swapIsBlockedWhileARecordingRuns() {
        withPersisted([:]) {
            let session = RecordingSession()
            #expect(session.swapBlockedReason == nil)
            session.isRunning = true
            #expect(session.swapBlockedReason == "录制中不能互换，停止后再试")
            #expect(!session.canSwapTranscriptionDirection)
        }
    }

    /// Auto-detect on a local model, swap to speaking, then switch to the
    /// system recognizer (which has no "自动"): the way back to listening
    /// must stay open.
    @Test func switchingToSystemWhileSpeakingDoesNotTrapTheDirection() throws {
        let variant = try #require(ProviderCatalog.modelVariants(forEngineID: "model.r2t2").first)
        let manager = try makeDownloadManager(withDownloaded: variant)
        withPersisted([
            PersistedSettingsKey.transcriptionEngineID: "model.r2t2",
            PersistedSettingsKey.sourceLanguageCode: "",
        ]) {
            let session = RecordingSession(modelDownloadManager: manager)
            #expect(session.sourceLanguageCode == nil)
            #expect(session.swapBlockedReason == nil)
            session.swapTranscriptionDirection()
            #expect(session.languages.transcriptionDirection == .speakMine)
            #expect(session.sourceLanguageCode == "zh-CN")

            session.transcriptionEngineID = "system.speech"
            #expect(!session.languages.foreignLanguageAutoDetect)
            #expect(session.swapBlockedReason == nil)
            session.swapTranscriptionDirection()
            #expect(session.sourceLanguageCode == "en-US")
            #expect(session.targetLanguageCode == "zh-CN")
        }
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

    @Test func whitespaceOnlyPersistedTargetLanguageCodeIsIgnored() {
        withPersisted([PersistedSettingsKey.targetLanguageCode: "   "]) {
            let session = RecordingSession()
            #expect(session.targetLanguageCode == "zh-CN")
        }
    }

    @Test func refreshDevicesDoesNotChangeSelectionWhileSessionIsActive() {
        // A running session's MicrophoneCapture is already bound to
        // whatever device start() handed it — reconciling selectedDeviceID
        // mid-recording would desync the UI from what's actually being
        // captured, since it can't hot-swap.
        withPersisted([PersistedSettingsKey.selectedDeviceID: "disconnected-device-id"]) {
            let session = RecordingSession()
            session.isRunning = true
            session.refreshDevices()
            #expect(session.selectedDeviceID == "disconnected-device-id")
            session.isRunning = false
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

    @Test func currentModelVariantDefaultsToTheCatalogsFirstEntryWhenUnselected() {
        defer { defaults.removeObject(forKey: PersistedSettingsKey.transcriptionEngineID) }
        let session = RecordingSession()
        session.transcriptionEngineID = "model.r2t2"
        #expect(session.transcriptionModelVariantID == nil)
        #expect(session.currentTranscriptionModelVariant?.id == ProviderCatalog.modelVariants(forEngineID: "model.r2t2").first?.id)
    }

    @Test func recognizedPersistedModelVariantIDIsRestored() throws {
        let variant = try #require(ProviderCatalog.modelVariants(forEngineID: "model.r2t2").first { $0.id == "r2t2-q8_0" })
        let manager = try makeDownloadManager(withDownloaded: variant)
        withPersisted([
            PersistedSettingsKey.transcriptionEngineID: "model.r2t2",
            PersistedSettingsKey.transcriptionModelVariantID: "r2t2-q8_0",
        ]) {
            let session = RecordingSession(modelDownloadManager: manager)
            #expect(session.transcriptionModelVariantID == "r2t2-q8_0")
            #expect(session.currentTranscriptionModelVariant?.id == "r2t2-q8_0")
        }
    }

    /// Guards `validateAndNormalizeModelVariantSelections()` — a variant ID
    /// left over from a since-renamed/removed catalog entry (or a corrupted
    /// defaults domain) must fall back to the current engine's first variant
    /// rather than resolving to no variant at all.
    @Test func unrecognizedPersistedModelVariantIDFallsBackToDefault() throws {
        let variant = try #require(ProviderCatalog.modelVariants(forEngineID: "model.r2t2").first)
        let manager = try makeDownloadManager(withDownloaded: variant)
        withPersisted([
            PersistedSettingsKey.transcriptionEngineID: "model.r2t2",
            PersistedSettingsKey.transcriptionModelVariantID: "bogus.variant.id",
        ]) {
            let session = RecordingSession(modelDownloadManager: manager)
            #expect(session.transcriptionModelVariantID == nil)
            #expect(session.currentTranscriptionModelVariant?.id == ProviderCatalog.modelVariants(forEngineID: "model.r2t2").first?.id)
        }
    }

    /// Deleting the selected variant while another of the same engine stays
    /// downloaded must move the selection onto the surviving one, instead of
    /// leaving it pointing at the deleted file (→ "尚未下载" on start/preload).
    @Test func deletingTheSelectedVariantReselectsADownloadedSibling() throws {
        let q8 = try #require(ProviderCatalog.variant(forID: "r2t2-q8_0"))
        let q4 = try #require(ProviderCatalog.variant(forID: "r2t2-q4_k_m"))
        let manager = try makeDownloadManager(withDownloaded: q8)
        FileManager.default.createFile(atPath: manager.localURL(for: q4).path, contents: Data())
        withPersisted([
            PersistedSettingsKey.transcriptionEngineID: "model.r2t2",
            PersistedSettingsKey.transcriptionModelVariantID: "r2t2-q4_k_m",
        ]) {
            let session = RecordingSession(modelDownloadManager: manager)
            #expect(session.transcriptionModelVariantID == "r2t2-q4_k_m", "both downloaded: selection stays")
            try? FileManager.default.removeItem(at: manager.localURL(for: q4))
            session.fallBackToSystemEngineIfModelUnavailable()
            #expect(session.transcriptionEngineID == "model.r2t2", "Q8_0 is still there: no fallback to system")
            #expect(session.transcriptionModelVariantID == "r2t2-q8_0")
            #expect(session.currentTranscriptionModelVariant?.id == "r2t2-q8_0")
        }
    }

    @Test func persistedSelectionOfAMissingVariantIsReselectedAtLaunch() throws {
        let q8 = try #require(ProviderCatalog.variant(forID: "r2t2-q8_0"))
        let manager = try makeDownloadManager(withDownloaded: q8)
        withPersisted([
            PersistedSettingsKey.transcriptionEngineID: "model.r2t2",
            PersistedSettingsKey.transcriptionModelVariantID: "r2t2-q4_k_m",
        ]) {
            let session = RecordingSession(modelDownloadManager: manager)
            #expect(session.transcriptionModelVariantID == "r2t2-q8_0")
        }
    }

    @Test func translationOnlyFallbackLeavesATranscriptionSelectionAlone() throws {
        let q8 = try #require(ProviderCatalog.variant(forID: "r2t2-q8_0"))
        let manager = try makeDownloadManager(withDownloaded: q8)
        withPersisted([
            PersistedSettingsKey.transcriptionEngineID: "model.r2t2",
            PersistedSettingsKey.transcriptionModelVariantID: "r2t2-q8_0",
        ]) {
            let session = RecordingSession(modelDownloadManager: manager)
            session.transcriptionModelVariantID = "r2t2-q4_k_m"  // picked, not downloaded yet
            session.fallBackToSystemEngineIfModelUnavailable(includingTranscription: false)
            #expect(session.transcriptionModelVariantID == "r2t2-q4_k_m")
        }
    }

    /// A variant selection only makes sense for the engine it was picked
    /// under — switching engines must drop a selection that doesn't belong
    /// to the new one, the same way `sourceLanguageCode` self-heals on an
    /// engine switch.
    @Test func switchingEngineDropsAModelVariantSelectionThatBelongsToTheOldEngine() {
        defer {
            defaults.removeObject(forKey: PersistedSettingsKey.transcriptionEngineID)
            defaults.removeObject(forKey: PersistedSettingsKey.transcriptionModelVariantID)
        }
        let session = RecordingSession()
        session.transcriptionEngineID = "model.r2t2"
        session.transcriptionModelVariantID = "r2t2-q8_0"
        #expect(session.transcriptionModelVariantID == "r2t2-q8_0")

        session.transcriptionEngineID = "system.speech"
        #expect(session.transcriptionModelVariantID == nil)
    }

    /// Guards a real bug: `loadedEngineIDs` used to only compare engine IDs,
    /// so switching a `.model` engine's selected variant while the
    /// *previous* variant's weights were already loaded left `isModelLoaded`
    /// reading "still matches" — `start()`/`preloadModel()` then silently
    /// kept running the stale variant forever instead of downloading/loading
    /// the newly-selected one. Simulates the "already loaded" state directly
    /// (`isModelLoaded`/`loadedEngineIDs`, both accessible for exactly this
    /// reason — see `loadedEngineIDs`'s own doc) rather than through a real
    /// `preloadModel()` call, which for a `.model` engine needs real
    /// R2T2/T3PO weights on the test machine or would attempt a real network
    /// download (same reasoning `preloadModelSetsIsModelLoadedForCurrentEngines`
    /// documents for using `.system` engines instead).
    @Test func changingModelVariantIDDiscardsAModelLoadedUnderADifferentVariant() {
        defer {
            defaults.removeObject(forKey: PersistedSettingsKey.transcriptionEngineID)
            defaults.removeObject(forKey: PersistedSettingsKey.transcriptionModelVariantID)
        }
        let session = RecordingSession()
        session.transcriptionEngineID = "model.r2t2"
        session.isModelLoaded = true
        session.loadedEngineIDs = (
            "model.r2t2", "some-old-variant-id",
            session.translationEngineID, session.currentTranslationModelVariant?.id
        )

        session.transcriptionModelVariantID = "r2t2-q8_0"

        #expect(!session.isModelLoaded)
    }

    /// Complements the above — reassigning the *same* (already-loaded)
    /// resolved variant must not discard a perfectly good load, same
    /// reasoning `reassigningTheSameEngineIDDoesNotDiscardALoadedModel`
    /// documents for engine IDs.
    @Test func reassigningTheSameResolvedModelVariantDoesNotDiscardALoadedModel() {
        defer {
            defaults.removeObject(forKey: PersistedSettingsKey.transcriptionEngineID)
            defaults.removeObject(forKey: PersistedSettingsKey.transcriptionModelVariantID)
        }
        let session = RecordingSession()
        session.transcriptionEngineID = "model.r2t2"
        session.transcriptionModelVariantID = "r2t2-q8_0"
        session.isModelLoaded = true
        session.loadedEngineIDs = (
            "model.r2t2", "r2t2-q8_0",
            session.translationEngineID, session.currentTranslationModelVariant?.id
        )

        session.transcriptionModelVariantID = "r2t2-q8_0"

        #expect(session.isModelLoaded)
    }

    /// Same fix, translation side — `translationModelVariantID`'s `didSet`
    /// must discard a model loaded under a different variant too, not just
    /// `transcriptionModelVariantID`'s.
    @Test func changingTranslationModelVariantIDDiscardsAModelLoadedUnderADifferentVariant() {
        defer {
            defaults.removeObject(forKey: PersistedSettingsKey.translationEngineID)
            defaults.removeObject(forKey: PersistedSettingsKey.translationModelVariantID)
        }
        let session = RecordingSession()
        session.translationEngineID = "model.t3po"
        session.isModelLoaded = true
        session.loadedEngineIDs = (
            session.transcriptionEngineID, session.currentTranscriptionModelVariant?.id,
            "model.t3po", "some-old-variant-id"
        )

        session.translationModelVariantID = "t3po-q5_k_m"

        #expect(!session.isModelLoaded)
    }

    @Test func usesOnDeviceModelEngineReflectsEitherEngineBeingModelKind() {
        defer {
            defaults.removeObject(forKey: PersistedSettingsKey.transcriptionEngineID)
            defaults.removeObject(forKey: PersistedSettingsKey.translationEngineID)
        }
        let session = RecordingSession()
        #expect(!session.usesOnDeviceModelEngine)

        session.transcriptionEngineID = "model.r2t2"
        #expect(session.usesOnDeviceModelEngine)
        session.transcriptionEngineID = "system.speech"
        #expect(!session.usesOnDeviceModelEngine)

        session.translationEngineID = "model.t3po"
        #expect(session.usesOnDeviceModelEngine)
    }

    /// Uses the default `.system` engines (no-op `loadModel()`, see
    /// `SystemTranscriptionProvider`/`SystemTranslationProvider`) so this
    /// exercises `preloadModel()`'s own state machine without depending on
    /// real R2T2/T3PO weights being present on the test machine.
    @Test func preloadModelSetsIsModelLoadedForCurrentEngines() async {
        let session = RecordingSession()
        #expect(!session.isModelLoaded)
        #expect(!session.isPreloadingModel)

        await session.preloadModel()

        #expect(session.isModelLoaded)
        #expect(!session.isPreloadingModel)
    }

    /// Guards `discardLoadedModelsIfStale()` — without it, switching engines
    /// after a load would leave `isModelLoaded` true for an engine pair
    /// `start()` was never actually asked to run, letting it wrongly skip
    /// `loadModel()` for the newly-selected engine.
    @Test func switchingEngineAfterPreloadDiscardsIt() async {
        defer { defaults.removeObject(forKey: PersistedSettingsKey.transcriptionEngineID) }
        let session = RecordingSession()
        await session.preloadModel()
        #expect(session.isModelLoaded)

        session.transcriptionEngineID = "model.r2t2"
        #expect(!session.isModelLoaded)
    }

    /// Guards `discardLoadedModelsIfStale()`'s `statusMessage` cleanup —
    /// without it, switching engines right after a successful preload left
    /// the panel's status bar permanently reading "模型已预加载" even though
    /// that model was just unloaded.
    @Test func switchingEngineAfterPreloadResetsTheStaleStatusMessage() async {
        defer { defaults.removeObject(forKey: PersistedSettingsKey.transcriptionEngineID) }
        let session = RecordingSession()
        await session.preloadModel()
        #expect(session.statusMessage == "模型已预加载")

        session.transcriptionEngineID = "model.r2t2"
        #expect(session.statusMessage == "未启动")
    }

    /// Guards `discardLoadedModelsIfStale()`'s staleness check — a
    /// `didSet` fires on *any* assignment, including one that re-sets the
    /// same value a `Picker` already had selected, so without comparing
    /// against the previously-loaded id this used to discard a perfectly
    /// good, still-matching load.
    @Test func reassigningTheSameEngineIDDoesNotDiscardALoadedModel() async {
        let session = RecordingSession()
        await session.preloadModel()
        #expect(session.isModelLoaded)

        session.transcriptionEngineID = session.transcriptionEngineID
        #expect(session.isModelLoaded)
    }

    /// `preloadModel()` is a no-op once already loaded — without this guard
    /// (see its own `!isModelLoaded` precondition), a second call would
    /// pointlessly reload an already-resident model.
    @Test func preloadModelIsANoOpOnceAlreadyLoaded() async {
        let session = RecordingSession()
        await session.preloadModel()
        #expect(session.isModelLoaded)

        session.statusMessage = "未启动"
        await session.preloadModel()
        // Didn't re-run the "预加载…" messaging path a second time.
        #expect(session.statusMessage == "未启动")
    }

    @Test func unloadModelsReleasesAPreloadedModel() async {
        let session = RecordingSession()
        await session.preloadModel()
        #expect(session.isModelLoaded)

        session.unloadModels()
        #expect(!session.isModelLoaded)
        #expect(session.statusMessage == "未启动")
    }

    /// Guards the one thing that makes `unloadModels()` (a user-initiated
    /// action, unlike `unloadModelsBeforeQuit()`) different from that
    /// quit-time counterpart: it must never pull a model out from under an
    /// active recording.
    @Test func unloadModelsIsANoOpWhileSessionIsActive() async {
        let session = RecordingSession()
        await session.preloadModel()
        #expect(session.isModelLoaded)

        session.isRunning = true
        session.unloadModels()
        #expect(session.isModelLoaded)
        session.isRunning = false
    }

    /// Guards against `unloadModels()` racing `preloadModel()`'s own
    /// in-flight `loadModel()` calls — `isPreloadingModel` isn't part of
    /// `isSessionActive`, so without its own guard, calling this mid-preload
    /// would nil out the provider ivars right before `preloadModel()`
    /// resumes and unconditionally sets `isModelLoaded = true`, leaving
    /// `isModelLoaded == true` with both providers actually `nil`.
    @Test func unloadModelsIsANoOpWhilePreloadingModel() async {
        let session = RecordingSession()
        await session.preloadModel()
        #expect(session.isModelLoaded)

        session.isPreloadingModel = true
        session.unloadModels()
        #expect(session.isModelLoaded)
        session.isPreloadingModel = false
    }

    /// `finalizeActiveSessionBeforeQuit()`'s no-op guard, for the common
    /// case (no `sessionStore` — the default `RecordingSession()` used
    /// throughout this suite — or nothing currently recording). The
    /// "actually closes out an orphaned in-progress session" path isn't
    /// covered here: reaching it requires `start()` to fully succeed
    /// (`isRunning == true`), which needs real mic capture/ASR permissions
    /// this sandboxed test environment can't reliably grant — any earlier
    /// failure already deletes the just-created `activeSessionRecord` via
    /// `start()`'s own cleanup `defer`.
    @Test func finalizeActiveSessionBeforeQuitIsANoOpWithNoActiveSession() {
        let session = RecordingSession()
        session.finalizeActiveSessionBeforeQuit()
    }

    /// `preloadModel()` must never surface a "尚未下载" failure to the user —
    /// `fallBackToSystemEngineIfModelUnavailable()` (called defensively at
    /// its own top) catches an undownloaded `.model` selection first and
    /// reverts it to the `.system` counterpart, so this call instead
    /// (successfully, if uselessly) preloads the system engine. Downloading
    /// is still never triggered implicitly here — only from
    /// `ModelManagementView`/`SettingsView`'s own inline shortcut. A fresh
    /// temp-directory `ModelDownloadManager` guarantees `isDownloaded` reads
    /// `false` for any variant without touching the network, so this needs
    /// no stubbing.
    @Test func preloadModelFallsBackToSystemEngineWhenTheSelectedVariantIsntDownloaded() async throws {
        defer { defaults.removeObject(forKey: PersistedSettingsKey.transcriptionEngineID) }
        let tempCacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelManagementTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempCacheDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempCacheDirectory) }

        let session = RecordingSession(modelDownloadManager: ModelDownloadManager(cacheDirectory: tempCacheDirectory))
        session.transcriptionEngineID = "model.r2t2"

        await session.preloadModel()

        #expect(session.isModelLoaded)
        #expect(session.transcriptionEngineID == "system.speech")
        #expect(!session.statusMessage.contains("尚未下载"))
    }

    /// Complements `recognizedPersistedTranscriptionEngineIDWithNothingDownloadedFallsBackToSystem`
    /// — the same self-heal applies to `translationEngineID` independently.
    @Test func recognizedPersistedTranslationEngineIDWithNothingDownloadedFallsBackToSystem() {
        withPersisted([PersistedSettingsKey.translationEngineID: "model.t3po"]) {
            let session = RecordingSession(modelDownloadManager: ModelDownloadManager(cacheDirectory: makeEmptyTempCacheDirectory()))
            #expect(session.translationEngineID == "system.translation")
        }
    }

    /// Complements `preloadModelFallsBackToSystemEngineWhenTheSelectedVariantIsntDownloaded`
    /// — the same fallback applies on the translation side independently of
    /// the transcription side.
    @Test func preloadModelFallsBackToSystemEngineForTranslationWhenTheSelectedVariantIsntDownloaded() async throws {
        defer { defaults.removeObject(forKey: PersistedSettingsKey.translationEngineID) }
        let session = RecordingSession(modelDownloadManager: ModelDownloadManager(cacheDirectory: makeEmptyTempCacheDirectory()))
        session.translationEngineID = "model.t3po"

        await session.preloadModel()

        #expect(session.isModelLoaded)
        #expect(session.translationEngineID == "system.translation")
        #expect(!session.statusMessage.contains("尚未下载"))
    }

    // MARK: - Floating panel opacity

    @Test func panelOpacityDefaultsMatchTheirDocumentedValues() {
        let session = RecordingSession()
        #expect(session.panelBackgroundOpacity == 0.5)
        #expect(session.panelContentOpacity == 1.0)
    }

    @Test func panelBackgroundOpacityIsRestoredFromPersistedValue() {
        withPersisted([PersistedSettingsKey.panelBackgroundOpacity: 0.75]) {
            let session = RecordingSession()
            #expect(session.panelBackgroundOpacity == 0.75)
        }
    }

    @Test func panelContentOpacityIsRestoredFromPersistedValue() {
        withPersisted([PersistedSettingsKey.panelContentOpacity: 0.6]) {
            let session = RecordingSession()
            #expect(session.panelContentOpacity == 0.6)
        }
    }

    /// `panelBackgroundOpacity`'s range (`0.1...1.0`) is wider than
    /// `panelContentOpacity`'s (`0.4...1.0`) — text/control legibility
    /// degrades badly well before full transparency, so its floor is
    /// meaningfully higher. Both clamp on assignment, not just at the
    /// `Slider` UI layer, since these are public, externally-settable
    /// properties.
    /// Also asserts the persisted value, not just the in-memory one — a
    /// prior version's `didSet` `return`ed right after reassigning `self`
    /// with the clamped value, silently skipping the `Self.defaults.set(...)`
    /// call below it for every out-of-range assignment (reassigning `self`
    /// from inside its own `didSet` does *not* re-trigger `didSet`, so
    /// nothing else ran that line for it either). A plain in-memory
    /// assertion alone wouldn't have caught that.
    @Test func panelBackgroundOpacityClampsToItsRange() {
        defer { defaults.removeObject(forKey: PersistedSettingsKey.panelBackgroundOpacity) }
        let session = RecordingSession()
        session.panelBackgroundOpacity = -1
        #expect(session.panelBackgroundOpacity == 0.1)
        #expect(defaults.double(forKey: PersistedSettingsKey.panelBackgroundOpacity) == 0.1)

        session.panelBackgroundOpacity = 5
        #expect(session.panelBackgroundOpacity == 1.0)
        #expect(defaults.double(forKey: PersistedSettingsKey.panelBackgroundOpacity) == 1.0)
    }

    /// See `panelBackgroundOpacityClampsToItsRange`'s doc for why this
    /// asserts the persisted value too.
    @Test func panelContentOpacityClampsToItsRange() {
        defer { defaults.removeObject(forKey: PersistedSettingsKey.panelContentOpacity) }
        let session = RecordingSession()
        session.panelContentOpacity = -1
        #expect(session.panelContentOpacity == 0.4)
        #expect(defaults.double(forKey: PersistedSettingsKey.panelContentOpacity) == 0.4)

        session.panelContentOpacity = 5
        #expect(session.panelContentOpacity == 1.0)
        #expect(defaults.double(forKey: PersistedSettingsKey.panelContentOpacity) == 1.0)
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

    @Test func translationCommitEagernessDefaultsToBalanced() {
        let session = RecordingSession()
        #expect(session.translationCommitEagerness == .balanced)
    }

    @Test func translationCommitEagernessIsRestoredFromPersistedValue() {
        withPersisted([PersistedSettingsKey.translationCommitEagerness: TranslationCommitEagerness.fast.rawValue]) {
            let session = RecordingSession()
            #expect(session.translationCommitEagerness == .fast)
        }
    }

    @Test func settingTranslationCommitEagernessPersistsIt() {
        defer { defaults.removeObject(forKey: PersistedSettingsKey.translationCommitEagerness) }
        let session = RecordingSession()
        session.translationCommitEagerness = .thorough
        #expect(defaults.string(forKey: PersistedSettingsKey.translationCommitEagerness) == "thorough")
    }

    @Test func translationEarlyTranslateThresholdDefaultsTo150() {
        let session = RecordingSession()
        #expect(session.translationEarlyTranslateThreshold == 150)
    }

    @Test func translationEarlyTranslateThresholdIsRestoredFromPersistedValue() {
        withPersisted([PersistedSettingsKey.translationEarlyTranslateThreshold: 300]) {
            let session = RecordingSession()
            #expect(session.translationEarlyTranslateThreshold == 300)
        }
    }

    @Test func settingTranslationEarlyTranslateThresholdPersistsIt() {
        defer { defaults.removeObject(forKey: PersistedSettingsKey.translationEarlyTranslateThreshold) }
        let session = RecordingSession()
        session.translationEarlyTranslateThreshold = 300
        #expect(defaults.integer(forKey: PersistedSettingsKey.translationEarlyTranslateThreshold) == 300)
    }

    @Test func translationEarlyTranslateThresholdClampsToItsRange() {
        defer { defaults.removeObject(forKey: PersistedSettingsKey.translationEarlyTranslateThreshold) }
        let session = RecordingSession()
        session.translationEarlyTranslateThreshold = 5
        #expect(session.translationEarlyTranslateThreshold == 20)

        session.translationEarlyTranslateThreshold = 5000
        #expect(session.translationEarlyTranslateThreshold == 1000)
    }

    @Test func vadSilenceDefaultsMatchTheirDocumentedValues() {
        let session = RecordingSession()
        #expect(session.vadSilenceSeconds == 0.6)
        #expect(session.vadSilenceDBFS == -40)
    }

    @Test func vadSilenceSettingsAreRestoredFromPersistedValue() {
        withPersisted([
            PersistedSettingsKey.vadSilenceSeconds: 1.2,
            PersistedSettingsKey.vadSilenceDBFS: -55.0,
        ]) {
            let session = RecordingSession()
            #expect(session.vadSilenceSeconds == 1.2)
            #expect(session.vadSilenceDBFS == -55)
        }
    }

    @Test func vadSilenceSettingsRestoredOutOfRangeAreClamped() {
        withPersisted([
            PersistedSettingsKey.vadSilenceSeconds: 0.0,
            PersistedSettingsKey.vadSilenceDBFS: 10.0,
        ]) {
            let session = RecordingSession()
            #expect(session.vadSilenceSeconds == 0.3)
            #expect(session.vadSilenceDBFS == -20)
        }
    }

    @Test func vadSilenceSettingsClampToTheirRangeAndPersist() {
        defer {
            defaults.removeObject(forKey: PersistedSettingsKey.vadSilenceSeconds)
            defaults.removeObject(forKey: PersistedSettingsKey.vadSilenceDBFS)
        }
        let session = RecordingSession()
        session.vadSilenceSeconds = 10
        session.vadSilenceDBFS = -100
        #expect(session.vadSilenceSeconds == 3.0)
        #expect(session.vadSilenceDBFS == -70)
        #expect(defaults.double(forKey: PersistedSettingsKey.vadSilenceSeconds) == 3.0)
        #expect(defaults.double(forKey: PersistedSettingsKey.vadSilenceDBFS) == -70)

        session.vadSilenceSeconds = 0
        session.vadSilenceDBFS = 0
        #expect(session.vadSilenceSeconds == 0.3)
        #expect(session.vadSilenceDBFS == -20)
    }

    @Test func refreshDevicesAlwaysOffersANoMicOption() {
        let session = RecordingSession()
        session.refreshDevices()
        #expect(session.inputDevices.contains(where: { $0.id == AudioInputDevice.noneID }))
    }

    /// `start()`'s very first guard — before any model loading or real audio
    /// capture — refuses "no mic, no system audio" (no audio source at all)
    /// with a friendly `statusMessage` rather than starting a session that
    /// will never transcribe anything. Safe to call in CI: this guard
    /// returns before `start()` ever touches `MicrophoneCapture`/
    /// `SystemAudioCapture`/model loading.
    @Test func startRefusesNoMicAndNoSystemAudio() async {
        let session = RecordingSession()
        session.selectedDeviceID = AudioInputDevice.noneID
        session.includeSystemAudio = false

        await session.start()

        #expect(!session.isRunning)
        #expect(session.statusMessage.contains("包含系统声音"))
    }

    @Test func appendTranslationInsertsASpaceBetweenFragmentsForASpaceSeparatedTargetLanguage() {
        let session = RecordingSession()
        session.targetLanguageCode = "en-US"

        session.appendTranslation("I went to the store.")
        session.appendTranslation("And bought some fruit.")

        #expect(session.lines[0].translation == "I went to the store. And bought some fruit.")
    }

    @Test func appendTranslationDoesNotInsertASpaceForACJKTargetLanguage() {
        let session = RecordingSession()
        session.targetLanguageCode = "zh-CN"

        session.appendTranslation("我去了商店。")
        session.appendTranslation("买了些水果。")

        #expect(session.lines[0].translation == "我去了商店。买了些水果。")
    }

    @Test func appendTranslationDoesNotDoubleUpAnAlreadyPresentSpace() {
        let session = RecordingSession()
        session.targetLanguageCode = "en-US"

        session.appendTranslation("Hello ")
        session.appendTranslation("world.")

        #expect(session.lines[0].translation == "Hello world.")
    }

    @Test func appendTranslationDoesNotInsertASpaceBeforeLeadingPunctuation() {
        let session = RecordingSession()
        session.targetLanguageCode = "en-US"

        session.appendTranslation("Hello")
        session.appendTranslation(", world.")

        #expect(session.lines[0].translation == "Hello, world.")
    }

    /// `.translationOnly` leaves the recognizer unloaded, so `isModelLoaded`
    /// (which `start()` reads as "both providers loaded") must stay false.
    @Test func translationOnlyPreloadDoesNotMarkFullPairLoaded() async {
        let session = RecordingSession()
        await session.preloadModel(scope: .translationOnly)
        #expect(session.hasLoadedModels)
        #expect(!session.isModelLoaded)
        #expect(session.loadedTranslationOnlyIDs?.engine == session.translationEngineID)
    }

    /// A later `.all` preload adopts the translation-only load and completes
    /// the pair; `unloadModels()` clears whichever state is held.
    @Test func fullPreloadAfterTranslationOnlyCompletesPair() async {
        let session = RecordingSession()
        await session.preloadModel(scope: .translationOnly)
        await session.preloadModel(scope: .all)
        #expect(session.isModelLoaded)
        #expect(session.loadedTranslationOnlyIDs == nil)
        session.unloadModels()
        #expect(!session.hasLoadedModels)
    }

    @Test func unloadClearsTranslationOnlyLoad() async {
        let session = RecordingSession()
        await session.preloadModel(scope: .translationOnly)
        session.unloadModels()
        #expect(!session.hasLoadedModels)
        #expect(session.loadedTranslationOnlyIDs == nil)
    }

    /// Switching the translation engine after a translation-only load must
    /// drop that load instead of leaving the old translator resident.
    @Test func switchingTranslationEngineDiscardsTranslationOnlyLoad() async {
        let session = RecordingSession()
        await session.preloadModel(scope: .translationOnly)
        #expect(session.loadedTranslationOnlyIDs != nil)
        session.translationEngineID = "model.hymt15"
        #expect(session.loadedTranslationOnlyIDs == nil)
        #expect(!session.hasLoadedModels)
    }

    /// A translation-only preload must not reset an undownloaded `.model`
    /// recognizer to the system engine as a side effect.
    @Test func translationOnlyPreloadKeepsUndownloadedRecognizerSelection() async {
        let session = RecordingSession(modelDownloadManager: ModelDownloadManager(cacheDirectory: makeEmptyTempCacheDirectory()))
        session.transcriptionEngineID = "model.r2t2"
        await session.preloadModel(scope: .translationOnly)
        #expect(session.transcriptionEngineID == "model.r2t2")
    }

    /// The deletion gate in the history window keys off this; with nothing
    /// recording there must be no protected record.
    @Test func liveSessionIDIsNilWhenIdle() {
        #expect(RecordingSession().liveSessionID == nil)
    }
}
