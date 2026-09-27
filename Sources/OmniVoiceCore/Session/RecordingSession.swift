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
        }
    }
    @Published public var translationEngineID: String = ProviderCatalog.translationEngines[0].id {
        didSet { Self.defaults.set(translationEngineID, forKey: PersistedSettingsKey.translationEngineID) }
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
        didSet { Self.defaults.set(targetLanguageCode, forKey: PersistedSettingsKey.targetLanguageCode) }
    }

    /// Nil only if `transcriptionEngineID` somehow doesn't match any known
    /// engine (shouldn't happen — it's only ever set from
    /// `ProviderCatalog.transcriptionEngines`).
    public var transcriptionEngineKind: EngineKind? {
        ProviderCatalog.transcriptionEngines.first { $0.id == transcriptionEngineID }?.kind
    }

    private let sessionStore: SessionStore?
    private var activeSessionRecord: RecordingSessionRecord?

    private var transcriptionProvider: TranscriptionProvider?
    private var translationProvider: TranslationProvider?
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

    public func start() async {
        guard !isRunning, !isStopping, !isStarting else { return }
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

        let transcription = Self.makeTranscriptionProvider(engineID: transcriptionEngineID)
        let translation = Self.makeTranslationProvider(engineID: translationEngineID)
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

        statusMessage = "加载翻译引擎中…"
        do {
            try await translation.loadModel()
            try await translation.start(config: TranslationConfig(
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: targetLanguageCode
            ))
        } catch {
            statusMessage = "翻译引擎启动失败: \(error.localizedDescription)"
            return
        }

        transcription.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }

        statusMessage = "加载识别引擎中…"
        do {
            try await transcription.loadModel()
            try await transcription.start(config: TranscriptionConfig(languageCode: sourceLanguageCode))
        } catch {
            statusMessage = "识别引擎启动失败: \(error.localizedDescription)"
            await translation.stop()
            return
        }

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
