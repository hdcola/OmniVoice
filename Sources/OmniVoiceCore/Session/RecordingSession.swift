import Foundation

/// Engine-agnostic recording orchestrator — the single place that wires
/// audio capture → `TranscriptionProvider` → `TranslationProvider` →
/// `lines`/persistence, regardless of which concrete engines are selected.
/// This is deliberately the *only* place that knows about
/// `TranscriptionEvent`'s three cases and how to turn them into display text
/// + translation feed calls — see that type's doc for the contract every
/// provider must uphold, and `handle(_:)` below for the resulting glue code.
///
/// Mirrors `mac-poc-hybrid`'s `AppModel`, generalized from "two hardcoded
/// engine switches" to "any `TranscriptionProvider`/`TranslationProvider`
/// pair, looked up by id in `ProviderCatalog`".
@MainActor
public final class RecordingSession: ObservableObject {
    @Published public var inputDevices: [AudioInputDevice] = []
    /// Persisted (see `PersistedSettingsKey`) — restored in `init()`, so a
    /// device picked last session stays picked after quitting/relaunching
    /// (or a system restart). `refreshDevices()` still reconciles it against
    /// whatever's actually connected right now.
    @Published public var selectedDeviceID: String? {
        didSet {
            guard !isReconcilingDevices else { return }
            Self.defaults.set(selectedDeviceID, forKey: PersistedSettingsKey.selectedDeviceID)
        }
    }
    @Published public var isRunning = false
    @Published public var isStopping = false
    /// True from the moment `start()` is called until its (possibly slow —
    /// model loading, device init) setup finishes and `isRunning` flips to
    /// `true`, or setup fails. Without this, `isRunning`/`isStopping` alone
    /// don't guard the window *during* that setup: a second `start()` call
    /// in that window would pass the same guard and create a second set of
    /// providers/capture, leaking the first and double-starting capture.
    @Published public var isStarting = false
    /// True while `preloadModel()`'s `loadModel()` calls are in flight —
    /// mirrors `isStarting`'s role but for the standalone preload path (see
    /// `preloadModel()`'s doc for why that's a separate entry point from
    /// `start()`).
    @Published public var isPreloadingModel = false
    /// True whenever `transcriptionProvider`/`translationProvider` currently
    /// hold a loaded pair matching today's engine selection
    /// (`loadedEngineIDs`) — whether that load happened via an explicit
    /// `preloadModel()` call or as a side effect of a previous `start()`.
    /// Deliberately survives `stop()`: a `.model`-kind engine's weights stay
    /// resident in memory across stop/start cycles (see `stop()`'s doc)
    /// instead of being reloaded from scratch on every "开始" — this flag
    /// (and the "预加载模型"/"模型已就绪" UI reading it) is what makes that
    /// visible instead of silently reloading anyway. Only goes false when
    /// the engine selection changes (`discardLoadedModelsIfStale()`) or the
    /// app is about to quit (`unloadModelsBeforeQuit()`).
    @Published public var isModelLoaded = false
    /// True across the whole `start()`→`stop()` lifecycle, not just while
    /// actually recording — use this (not `isRunning` alone) to gate any
    /// control whose value is only read once, at the top of `start()`
    /// (engine IDs, device, language, system-audio inclusion). `isRunning`
    /// alone leaves a window open during `isStarting`/`isStopping` where
    /// those controls look editable but a change either races the in-flight
    /// setup or silently won't apply to the run in progress.
    public var isSessionActive: Bool { isRunning || isStarting || isStopping }
    /// One row per ASR utterance/segment, source and translation aligned
    /// side by side.
    @Published public var lines: [TranscriptLine] = []
    @Published public var statusMessage: String = "未启动"
    @Published public var inputLevel: Float = 0
    /// Mix in system/output audio (ScreenCaptureKit) alongside the mic. Only
    /// changeable while stopped — the mixer/capture are constructed once in
    /// `start()`. Persisted (see `PersistedSettingsKey`).
    @Published public var includeSystemAudio: Bool = false {
        didSet { Self.defaults.set(includeSystemAudio, forKey: PersistedSettingsKey.includeSystemAudio) }
    }
    /// Set when `SystemAudioCapture.start()` throws — almost always means
    /// the Screen Recording TCC prompt hasn't been granted yet. Doesn't
    /// abort the run: mic-only transcription still proceeds.
    @Published public var screenRecordingPermissionNeeded = false

    /// Engine selection — only takes effect on the next `start()`, so a
    /// picker bound to these should be disabled while `isSessionActive`.
    /// Persisted (see `PersistedSettingsKey`).
    @Published public var transcriptionEngineID: String = ProviderCatalog.transcriptionEngines[0].id {
        didSet {
            // Keeps the "system engine ⇒ usable source language" invariant
            // that `start()` depends on (see `sourceLanguageCode`'s doc)
            // even when the engine is switched (in Settings/the panel)
            // *after* `sourceLanguageCode` was set to something only valid
            // for a `.model` engine (nil "自动", or one of the languages
            // `LanguageOption.supportsSystemASRSource` marks as
            // system-unsupported) — without this, switching back to
            // `.system` would leave a value guaranteed to throw at the next
            // `start()`. Same check `validateAndNormalizeSourceLanguage()`
            // runs after restoring persisted settings.
            validateAndNormalizeSourceLanguage()
            Self.defaults.set(transcriptionEngineID, forKey: PersistedSettingsKey.transcriptionEngineID)
            discardLoadedModelsIfStale()
        }
    }
    @Published public var translationEngineID: String = ProviderCatalog.translationEngines[0].id {
        didSet {
            Self.defaults.set(translationEngineID, forKey: PersistedSettingsKey.translationEngineID)
            discardLoadedModelsIfStale()
        }
    }
    /// BCP-47-ish language tags. `sourceLanguageCode` nil means "auto", only
    /// meaningful for `.model`-kind ASR engines — `.system` (`SpeechTranscriber`)
    /// requires a concrete one; `start()` fails with `.localeNotSupported`
    /// if left nil while a system engine is selected. A UI offering "自动"
    /// should only do so while `transcriptionEngineKind == .model`. Persisted
    /// (see `PersistedSettingsKey`) using `""` as nil's sentinel, since
    /// `UserDefaults` can't distinguish "never set" from "explicitly set to
    /// nil".
    @Published public var sourceLanguageCode: String? = "en-US" {
        didSet {
            Self.defaults.set(sourceLanguageCode ?? "", forKey: PersistedSettingsKey.sourceLanguageCode)
        }
    }
    @Published public var targetLanguageCode: String = "zh-CN" {
        didSet {
            Self.defaults.set(targetLanguageCode, forKey: PersistedSettingsKey.targetLanguageCode)
            // Unlike `sourceLanguageCode`/the engine ID properties, this one
            // stays editable *while* a recording is running (see
            // `TargetLanguagePicker`'s doc in `FloatingTranscriptView`) —
            // for `SystemTranslationProvider`, that already worked via
            // `.translationTask` rebuilding on every change, but a
            // `.model`-kind engine like T3PO has no such rebuild hook and
            // was silently continuing to translate into whatever language
            // `start(config:)` set until this was added. Safe to call
            // whether or not a recording is active — `translationProvider`
            // is nil when stopped, and `updateTargetLanguage(_:)`'s default
            // no-op is a deliberate no-op for providers with nothing to
            // retarget (see that method's doc).
            translationProvider?.updateTargetLanguage(targetLanguageCode)
        }
    }

    /// Nil only if `transcriptionEngineID` somehow doesn't match any known
    /// engine (shouldn't happen — it's only ever set from
    /// `ProviderCatalog.transcriptionEngines`).
    public var transcriptionEngineKind: EngineKind? {
        ProviderCatalog.transcriptionEngines.first { $0.id == transcriptionEngineID }?.kind
    }

    public var translationEngineKind: EngineKind? {
        ProviderCatalog.translationEngines.first { $0.id == translationEngineID }?.kind
    }

    /// Whether preloading is actually worth offering — a `.system` engine's
    /// `loadModel()` is a no-op, so a preload button would just be a slower
    /// no-op button when neither selected engine is `.model`-kind.
    public var usesOnDeviceModelEngine: Bool {
        transcriptionEngineKind == .model || translationEngineKind == .model
    }

    private let sessionStore: SessionStore?
    private var activeSessionRecord: RecordingSessionRecord?

    private var transcriptionProvider: TranscriptionProvider?
    private var translationProvider: TranslationProvider?
    /// The `(transcriptionEngineID, translationEngineID)` pair
    /// `transcriptionProvider`/`translationProvider` are currently loaded
    /// for, whenever they hold a loaded pair rather than `nil`/stale
    /// instances. Distinct from just checking `isModelLoaded` because
    /// `start()` needs to know the load actually matches the *current*
    /// engine selection, not a stale one left over before a switch
    /// (`discardLoadedModelsIfStale()` normally clears this first, but the
    /// two aren't atomic with each other, so `start()` re-checks).
    private var loadedEngineIDs: (transcription: String, translation: String)?
    private var micCapture: MicrophoneCapture?
    private var systemAudioCapture: SystemAudioCapture?
    private var mixer: AudioMixer?
    private var vadSegmenter: UtteranceSegmenter?

    /// `lines` index the currently-open ASR segment writes to.
    private var sourceRowIndex = 0
    /// Persistent across stop/start cycles — see `SystemTranslationProvider`'s
    /// doc for why the bridge continuation lives here rather than on a
    /// per-run provider instance.
    private var translationBridgeContinuation: AsyncStream<TranslationBridgeRequest>.Continuation?

    /// `lines` index the currently-open translation commits write to —
    /// tracked separately from `sourceRowIndex` because a streaming
    /// translation engine's commits can lag behind ASR segment closes,
    /// arriving on their own queue (strictly in row order) rather than in
    /// lockstep with them. A one-shot engine (bridged through
    /// `SystemTranslationProvider`) happens to keep the two in lockstep, but
    /// `RecordingSession` doesn't assume that.
    private var translationRowIndex = 0

    public init(sessionStore: SessionStore? = nil) {
        self.sessionStore = sessionStore
        restorePersistedSettings()
    }

    /// Restores whatever settings were persisted from a previous run —
    /// without this, every quit/relaunch (or system restart) silently reset
    /// engine choice, language, mic, and system-audio inclusion back to
    /// their hardcoded defaults above, which is surprising for anything the
    /// user deliberately configured last time. Each property's own `didSet`
    /// (see their declarations) does fire for these assignments (a stored
    /// property that already has a declared default value, like all of
    /// these, gets its `didSet` called even for an assignment made from
    /// within `init()`) — but `transcriptionEngineID`'s self-heal `didSet`
    /// runs *before* `sourceLanguageCode` below is restored, so it validates
    /// against the not-yet-restored (still-default) value and can't catch
    /// an invariant violation that only exists after both are restored.
    /// `validateAndNormalizeSourceLanguage()` below re-checks once
    /// everything's loaded, closing that gap.
    private func restorePersistedSettings() {
        let defaults = Self.defaults
        // Guards against a value from a build where an engine ID was since
        // renamed/removed (or, in principle, a corrupted defaults domain) —
        // an unrecognized ID would make `transcriptionEngineKind` return
        // `nil`, silently breaking every `.system`/`.model` check that
        // depends on it (`makeTranscriptionProvider`'s `switch` still falls
        // back to a concrete provider, but the *language* logic doesn't).
        if let value = defaults.string(forKey: PersistedSettingsKey.transcriptionEngineID),
           ProviderCatalog.transcriptionEngines.contains(where: { $0.id == value }) {
            transcriptionEngineID = value
        }
        if let value = defaults.string(forKey: PersistedSettingsKey.translationEngineID),
           ProviderCatalog.translationEngines.contains(where: { $0.id == value }) {
            translationEngineID = value
        }
        if let value = defaults.string(forKey: PersistedSettingsKey.sourceLanguageCode) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            sourceLanguageCode = trimmed.isEmpty ? nil : trimmed
        }
        if let value = defaults.string(forKey: PersistedSettingsKey.targetLanguageCode) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                targetLanguageCode = trimmed
            }
        }
        if defaults.object(forKey: PersistedSettingsKey.includeSystemAudio) != nil {
            includeSystemAudio = defaults.bool(forKey: PersistedSettingsKey.includeSystemAudio)
        }
        selectedDeviceID = defaults.string(forKey: PersistedSettingsKey.selectedDeviceID)

        validateAndNormalizeSourceLanguage()
    }

    /// Same invariant `transcriptionEngineID`'s `didSet` self-heals on an
    /// engine switch — re-checked here because restoring settings can
    /// arrive at an invalid combination that neither individual restore
    /// step above would have caught on its own (see `restorePersistedSettings()`'s
    /// doc).
    private func validateAndNormalizeSourceLanguage() {
        guard transcriptionEngineKind == .system else { return }
        let isUnsupportedForSystemASR = sourceLanguageCode.map { code in
            LanguageCatalog.common.first { $0.code == code }?.supportsSystemASRSource == false
        } ?? true
        if isUnsupportedForSystemASR {
            sourceLanguageCode = "en-US"
        }
    }

    /// `refreshDevices()`'s own fallback (below) intentionally does *not*
    /// go through `selectedDeviceID`'s normal persisting `didSet` — without
    /// this flag, plugging out a USB mic/disconnecting Bluetooth earbuds and
    /// then just opening the menu (which calls `refreshDevices()`) would
    /// silently overwrite the persisted device preference with
    /// `.systemDefault`, permanently forgetting it even after the real
    /// device is reconnected.
    private var isReconcilingDevices = false

    public func refreshDevices() {
        inputDevices = [.systemDefault] + MicrophoneCapture.availableDevices()

        // Reconciling/switching `selectedDeviceID` while a recording is
        // active would just desync the UI from reality: `start()` already
        // handed the *original* device to `MicrophoneCapture`, which can't
        // hot-swap mid-recording, so changing this property now wouldn't
        // change what's actually being captured. Still refresh
        // `inputDevices` above so the (disabled) picker's list itself stays
        // current.
        guard !isSessionActive else { return }

        // Prefer the persisted device over whatever `selectedDeviceID`
        // currently holds: once a disconnect falls back to `.systemDefault`
        // (below), `.systemDefault` is *always* present in `inputDevices`,
        // so the plain "is the current selection still valid" check below
        // would never re-trigger once the preferred device reconnects —
        // this in-session switch-back needs its own check against the
        // persisted preference, not just against the current selection.
        let preferredID = Self.defaults.string(forKey: PersistedSettingsKey.selectedDeviceID)
        if let preferredID, inputDevices.contains(where: { $0.id == preferredID }) {
            if selectedDeviceID != preferredID {
                isReconcilingDevices = true
                selectedDeviceID = preferredID
                isReconcilingDevices = false
            }
        } else if selectedDeviceID == nil || !inputDevices.contains(where: { $0.id == selectedDeviceID }) {
            isReconcilingDevices = true
            selectedDeviceID = inputDevices.first?.id
            isReconcilingDevices = false
        }
    }

    // MARK: - Lifecycle

    /// Loads the currently-selected transcription/translation engines ahead
    /// of `start()`, so a `.model`-kind engine's (often multi-second) weight
    /// load happens while the user is still deciding to record rather than
    /// after they've already asked to — without this, that load only ever
    /// ran inside `start()` itself, making the very first "开始" of a
    /// session look stalled with no visible progress beyond `statusMessage`.
    /// A no-op-ish fast path for `.system` engines (their `loadModel()` does
    /// nothing) — still safe to call, just not very useful there.
    ///
    /// Leaves the loaded providers in `transcriptionProvider`/
    /// `translationProvider` for `start()` to adopt directly (skipping its
    /// own `loadModel()` calls) as long as the engine selection hasn't
    /// changed since — see `loadedEngineIDs`.
    public func preloadModel() async {
        guard !isSessionActive, !isPreloadingModel, !isModelLoaded else { return }
        isPreloadingModel = true
        defer { isPreloadingModel = false }

        let transcription = Self.makeTranscriptionProvider(engineID: transcriptionEngineID)
        let translation = Self.makeTranslationProvider(engineID: translationEngineID)
        // Wired into the ivars immediately — *before* either `loadModel()`
        // call below resolves, not after both succeed. `unloadModelsBeforeQuit()`
        // reads these same ivars, and it needs something to reach even if
        // the app quits mid-load: leaving them `nil` until success meant
        // quitting during a multi-second preload skipped `unload()`
        // entirely, risking exactly the ggml Metal exit-time assert
        // `unloadModelsBeforeQuit()` exists to prevent (see its doc).
        transcriptionProvider = transcription
        translationProvider = translation

        statusMessage = "预加载翻译引擎中…"
        do {
            try await translation.loadModel()
        } catch {
            statusMessage = "翻译引擎预加载失败: \(error.localizedDescription)"
            translation.unload()
            transcriptionProvider = nil
            translationProvider = nil
            return
        }

        statusMessage = "预加载识别引擎中…"
        do {
            try await transcription.loadModel()
        } catch {
            statusMessage = "识别引擎预加载失败: \(error.localizedDescription)"
            translation.unload()
            transcription.unload()
            transcriptionProvider = nil
            translationProvider = nil
            return
        }

        loadedEngineIDs = (transcriptionEngineID, translationEngineID)
        isModelLoaded = true
        statusMessage = "模型已预加载"
    }

    /// Unloads and discards a load left over from before an engine switch —
    /// called from `transcriptionEngineID`/`translationEngineID`'s `didSet`.
    /// Without this, switching engines after loading kept the *old*
    /// engine's provider sitting in `transcriptionProvider`/
    /// `translationProvider`, which `start()`'s reuse check below would
    /// never actually pick (its own engine-ID comparison catches that), but
    /// would otherwise just leak a loaded model that's no longer reachable
    /// through `preloadModel()`'s `isModelLoaded` guard.
    private func discardLoadedModelsIfStale() {
        guard let loaded = loadedEngineIDs else { return }
        // Re-assigning the *same* engine ID a Picker already has selected
        // still fires this `didSet` — without this check, that (a no-op as
        // far as the actual selection goes) would unconditionally discard a
        // perfectly good, still-matching load.
        guard loaded.transcription != transcriptionEngineID || loaded.translation != translationEngineID else {
            return
        }
        transcriptionProvider?.unload()
        translationProvider?.unload()
        transcriptionProvider = nil
        translationProvider = nil
        loadedEngineIDs = nil
        isModelLoaded = false
        // Only when it's still showing what `preloadModel()` last set it to
        // — never stomps a message from something else entirely unrelated
        // to preloading (a recording in progress, a prior error, ...).
        // Without this, switching engines right after a successful preload
        // left the panel's status bar reading "模型已预加载" indefinitely,
        // even though that model was just unloaded.
        if statusMessage == "模型已预加载" {
            statusMessage = "未启动"
        }
    }

    /// Synchronously releases any loaded model backend before the app quits
    /// — call from `applicationWillTerminate`. Required specifically for
    /// `.model`-kind engines: leaving R2T2/T3PO's GPU (Metal) resources
    /// alive past process exit trips ggml's exit-time assert (see
    /// `InProcessTranslator.unload()`'s doc); `.system` providers' `unload()`
    /// is a no-op, so this is harmless to call unconditionally. Not `async`
    /// on purpose — every concrete `unload()` is synchronous, and
    /// `applicationWillTerminate` gives no opportunity to await one that
    /// wasn't.
    public func unloadModelsBeforeQuit() {
        performModelUnload()
    }

    /// User-initiated release of a currently-loaded `.model`-kind engine —
    /// e.g. the floating panel's "模型已就绪" context menu offering "释放模型".
    /// `isModelLoaded` otherwise only goes away on an engine switch or quit
    /// (see its own doc); this is for reclaiming the memory/VRAM sooner on
    /// a memory-constrained machine, without either of those. Guarded by
    /// `!isSessionActive` — unlike `unloadModelsBeforeQuit()` (called at
    /// quit, when nothing else matters), unloading out from under an active
    /// recording would break it outright.
    public func unloadModels() {
        guard !isSessionActive else { return }
        performModelUnload()
    }

    private func performModelUnload() {
        transcriptionProvider?.unload()
        translationProvider?.unload()
        transcriptionProvider = nil
        translationProvider = nil
        loadedEngineIDs = nil
        isModelLoaded = false
        if statusMessage == "模型已预加载" {
            statusMessage = "未启动"
        }
    }

    public func start() async {
        guard !isRunning, !isStopping, !isStarting, !isPreloadingModel else { return }
        isStarting = true
        defer { isStarting = false }
        // `activeSessionRecord` is created below, before translation/
        // transcription/mic are actually up — any of those failing (several
        // `catch` blocks below `return` early) left that record as a
        // permanent orphan: no `endedAt`, no utterances, and un-reachable
        // once the *next* successful `start()` overwrites
        // `activeSessionRecord` with a new one. `isRunning` only ever
        // becomes `true` on the success path at the very end, so "this
        // defer still finds `isRunning == false`" reliably means "we're
        // exiting via one of the early-failure returns" — clean up the
        // orphan there instead of duplicating cleanup in every `catch`.
        // `lines` is reset the same way: `lines = [TranscriptLine(id: 0)]`
        // below runs before any of those same failure points, so without
        // this a failed `start()` left one empty row behind — `lines.isEmpty`
        // then reads `false`, so `FloatingTranscriptView`'s "等待开始…"
        // placeholder never shows and the panel just looks blank, with no
        // indication anything went wrong (that's `statusMessage`'s job —
        // see `FloatingTranscriptView.statusBar`).
        defer {
            if !isRunning {
                lines = []
                if let sessionStore, let orphan = activeSessionRecord {
                    sessionStore.delete(orphan)
                    try? sessionStore.save()
                    activeSessionRecord = nil
                }
            }
        }

        // Adopt an already-loaded pair rather than loading fresh below —
        // whether that pair came from an explicit `preloadModel()` call or
        // (just as often) is simply left over from a previous recording's
        // `start()`, since `stop()` deliberately doesn't unload (see its
        // doc). The engine-ID comparison guards against a load left over
        // for a since-switched-away-from engine slipping through if
        // `discardLoadedModelsIfStale()` hasn't run for some reason. The
        // `transcriptionProvider`/`translationProvider` non-nil checks are
        // folded into this same boolean, not left as a separate `if let`
        // below — `reusingLoaded` is also read much further down (guarding
        // whether `loadModel()` gets called at all), so if those checks
        // lived only in the branch condition, an `isModelLoaded`-true-but-
        // `transcriptionProvider`-nil edge case would fall into the `else`
        // branch (creating fresh, unloaded providers) while `reusingLoaded`
        // itself stayed `true` — skipping `loadModel()` for a provider that
        // was never actually loaded, and failing at `startStream()` with
        // `TranscriberError.notLoaded`.
        let reusingLoaded = isModelLoaded
            && loadedEngineIDs?.transcription == transcriptionEngineID
            && loadedEngineIDs?.translation == translationEngineID
            && transcriptionProvider != nil
            && translationProvider != nil
        let transcription: TranscriptionProvider
        let translation: TranslationProvider
        if reusingLoaded, let loadedTranscription = transcriptionProvider, let loadedTranslation = translationProvider {
            transcription = loadedTranscription
            translation = loadedTranslation
        } else {
            transcription = Self.makeTranscriptionProvider(engineID: transcriptionEngineID)
            translation = Self.makeTranslationProvider(engineID: translationEngineID)
        }
        transcriptionProvider = transcription
        translationProvider = translation

        lines = [TranscriptLine(id: 0)]
        sourceRowIndex = 0
        translationRowIndex = 0
        screenRecordingPermissionNeeded = false

        if let sessionStore {
            activeSessionRecord = sessionStore.createSession(
                title: Self.defaultTitle(),
                transcriptionEngineID: transcriptionEngineID,
                translationEngineID: translationEngineID,
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: targetLanguageCode
            )
        }

        if let systemTranslation = translation as? SystemTranslationProvider {
            systemTranslation.onBridgeRequest = { [weak self] request in
                self?.translationBridgeContinuation?.yield(request)
            }
        }

        translation.onCommit = { [weak self] text in
            Task { @MainActor in self?.appendTranslation(text) }
        }
        translation.onPreview = { [weak self] text in
            Task { @MainActor in self?.updateTranslationPreview(text) }
        }
        translation.onFlushBoundary = { [weak self] in
            Task { @MainActor in self?.advanceTranslationRow() }
        }

        statusMessage = reusingLoaded ? "启动翻译引擎中…" : "加载翻译引擎中…"
        do {
            if !reusingLoaded {
                try await translation.loadModel()
            }
            try await translation.start(config: TranslationConfig(
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: targetLanguageCode
            ))
        } catch {
            statusMessage = "翻译引擎启动失败: \(error.localizedDescription)"
            // Only tear down a load this call itself just performed — if
            // `reusingLoaded`, the model was already loaded fine before
            // this `start()` even ran; this failure is `start(config:)`'s
            // alone, so leave it loaded for a retry instead of discarding
            // a perfectly good load.
            if !reusingLoaded {
                translation.unload()
                transcriptionProvider = nil
                translationProvider = nil
            }
            return
        }

        transcription.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }

        statusMessage = reusingLoaded ? "启动识别引擎中…" : "加载识别引擎中…"
        do {
            if !reusingLoaded {
                try await transcription.loadModel()
            }
            try await transcription.start(config: TranscriptionConfig(languageCode: sourceLanguageCode))
        } catch {
            statusMessage = "识别引擎启动失败: \(error.localizedDescription)"
            await translation.stop()
            // Same reasoning as the translation catch above.
            if !reusingLoaded {
                translation.unload()
                transcription.unload()
                transcriptionProvider = nil
                translationProvider = nil
            }
            return
        }

        // Both engines are now loaded and started for this exact pair —
        // record that regardless of whether this call freshly loaded them
        // or reused an already-loaded pair, so `stop()` (which doesn't
        // unload) leaves them ready for the *next* `start()` to reuse too.
        loadedEngineIDs = (transcriptionEngineID, translationEngineID)
        isModelLoaded = true

        let segmenter = UtteranceSegmenter()
        segmenter.onUtteranceBoundary = { [weak transcription] in
            transcription?.notifyUtteranceBoundary()
        }
        vadSegmenter = segmenter

        let mixer = AudioMixer(includeSystemAudio: includeSystemAudio)
        mixer.onPCMChunk = { [weak transcription] samples in
            transcription?.push(samples: samples)
        }
        mixer.onLevel = { [weak self] level in
            Task { @MainActor in self?.updateLevel(level) }
        }
        self.mixer = mixer

        let mic = MicrophoneCapture(deviceID: selectedDeviceID)
        mic.onBuffer = { [weak mixer, weak segmenter] samples in
            mixer?.submitMic(samples)
            segmenter?.submit(samples)
        }
        do {
            try mic.start()
        } catch {
            statusMessage = "麦克风启动失败: \(error.localizedDescription)"
            await transcription.stop()
            await translation.stop()
            return
        }
        micCapture = mic

        if includeSystemAudio {
            let sys = SystemAudioCapture()
            sys.onBuffer = { [weak mixer] samples in mixer?.submitSystemAudio(samples) }
            do {
                try await sys.start()
                systemAudioCapture = sys
            } catch {
                screenRecordingPermissionNeeded = true
                statusMessage = "系统音频启动失败（可能需要在系统设置里授权屏幕录制权限）: \(error.localizedDescription)"
            }
        }

        isRunning = true
        if !screenRecordingPermissionNeeded {
            statusMessage = "转写中…"
        }
    }

    public func stop() async {
        guard isRunning, !isStopping else { return }
        isStopping = true
        micCapture?.stop()
        micCapture = nil
        systemAudioCapture?.stop()
        systemAudioCapture = nil
        mixer = nil
        vadSegmenter = nil

        // Ends this recording's stream/session on each provider without
        // unloading its model — `transcriptionProvider`/`translationProvider`
        // (and `isModelLoaded`) stay as they are so the *next* `start()`
        // reuses them instead of reloading weights from scratch. Only an
        // engine switch (`discardLoadedModelsIfStale()`) or quitting
        // (`unloadModelsBeforeQuit()`) actually unloads.
        await transcriptionProvider?.stop()
        await translationProvider?.stop()

        if let sessionStore, let activeSessionRecord {
            sessionStore.endSession(activeSessionRecord)
            try? sessionStore.save()
        }
        activeSessionRecord = nil

        isRunning = false
        isStopping = false
        statusMessage = "已停止"
        inputLevel = 0
    }

    // MARK: - Bridging for one-shot (`.system`-kind) translation engines

    /// A long-lived SwiftUI view drains this with `.translationTask` to
    /// perform the actual `TranslationSession` call (which can only happen
    /// inside a view) and reports results back via
    /// `resolveTranslationBridgeResult(_:)`. Call once, when that view
    /// mounts — not per recording — since this continuation is meant to
    /// outlive individual start/stop cycles (see `SystemTranslationProvider`'s
    /// doc). Yields nothing while the active translation engine isn't a
    /// `SystemTranslationProvider`.
    public func translationBridgeStream() -> AsyncStream<TranslationBridgeRequest> {
        let (stream, continuation) = AsyncStream<TranslationBridgeRequest>.makeStream()
        translationBridgeContinuation = continuation
        return stream
    }

    public func resolveTranslationBridgeResult(_ text: String) {
        (translationProvider as? SystemTranslationProvider)?.receiveResult(text)
    }

    public var currentSourceLanguage: Locale.Language? {
        sourceLanguageCode.map { Locale.Language(identifier: $0) }
    }

    public var currentTargetLanguage: Locale.Language {
        Locale.Language(identifier: targetLanguageCode)
    }

    // MARK: - Transcription event handling (engine-agnostic)

    private func handle(_ event: TranscriptionEvent) {
        switch event {
        case .appended(let text):
            ensureLine(sourceRowIndex)
            lines[sourceRowIndex].source += text
            translationProvider?.feed(text)

        case .revised(let text):
            ensureLine(sourceRowIndex)
            lines[sourceRowIndex].sourceTentative = text

        case .segmentClosed(let finalAppend):
            ensureLine(sourceRowIndex)
            if !finalAppend.isEmpty {
                lines[sourceRowIndex].source += finalAppend
                translationProvider?.feed(finalAppend)
            }
            lines[sourceRowIndex].sourceTentative = ""
            translationProvider?.flush()
            sourceRowIndex += 1
            ensureLine(sourceRowIndex)
        }
    }

    private func appendTranslation(_ text: String) {
        ensureLine(translationRowIndex)
        lines[translationRowIndex].translation += text
        lines[translationRowIndex].translationPreview = ""
    }

    private func updateTranslationPreview(_ text: String) {
        ensureLine(translationRowIndex)
        lines[translationRowIndex].translationPreview = text
    }

    /// A translation `flush()` boundary — this row's translation (whatever
    /// arrived via `onCommit` before this point) is now final, so this is
    /// where the row actually gets persisted.
    private func advanceTranslationRow() {
        if let sessionStore, let activeSessionRecord, translationRowIndex < lines.count {
            let row = lines[translationRowIndex]
            sessionStore.appendUtterance(to: activeSessionRecord, sourceText: row.source, translationText: row.translation)
            try? sessionStore.save()
        }
        translationRowIndex += 1
        ensureLine(translationRowIndex)
    }

    // MARK: - Shared

    private func ensureLine(_ index: Int) {
        while lines.count <= index {
            lines.append(TranscriptLine(id: lines.count))
        }
    }

    /// Fast attack / slow decay smoothing so the meter reacts instantly to
    /// louder sound but doesn't flicker down to zero between syllables.
    private func updateLevel(_ level: Float) {
        if level > inputLevel {
            inputLevel = level
        } else {
            inputLevel = inputLevel * 0.7 + level * 0.3
        }
    }

    private static func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: .now)
    }

    private static func makeTranscriptionProvider(engineID: String) -> TranscriptionProvider {
        switch ProviderCatalog.transcriptionEngines.first(where: { $0.id == engineID })?.kind {
        case .model: return ModelTranscriptionProvider()
        default: return SystemTranscriptionProvider()
        }
    }

    private static func makeTranslationProvider(engineID: String) -> TranslationProvider {
        switch ProviderCatalog.translationEngines.first(where: { $0.id == engineID })?.kind {
        case .model: return ModelTranslationProvider()
        default: return SystemTranslationProvider()
        }
    }

    private static let defaults = UserDefaults.standard
}

/// Namespaced (`org.omnivoice.*`) to avoid colliding with anything else
/// ever written into the app's `UserDefaults` domain. Internal, not
/// `private`, so `RecordingSessionSettingsTests` can drive
/// `restorePersistedSettings()`'s self-heal paths through the same
/// `UserDefaults` keys `RecordingSession` itself reads/writes.
enum PersistedSettingsKey {
    static let transcriptionEngineID = "org.omnivoice.transcriptionEngineID"
    static let translationEngineID = "org.omnivoice.translationEngineID"
    static let sourceLanguageCode = "org.omnivoice.sourceLanguageCode"
    static let targetLanguageCode = "org.omnivoice.targetLanguageCode"
    static let includeSystemAudio = "org.omnivoice.includeSystemAudio"
    static let selectedDeviceID = "org.omnivoice.selectedDeviceID"
}
