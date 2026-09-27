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
        didSet { Self.defaults.set(selectedDeviceID, forKey: PersistedSettingsKey.selectedDeviceID) }
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
            // Keeps the "system engine ⇒ concrete source language" invariant
            // that `start()` depends on (see `sourceLanguageCode`'s doc)
            // even when the engine is switched (in Settings) *after* the
            // user picked "自动" while a `.model` engine was selected —
            // without this, switching back to a `.system` engine would
            // leave `sourceLanguageCode` at `nil` and the next `start()`
            // would throw `.localeNotSupported`.
            if transcriptionEngineKind == .system, sourceLanguageCode == nil {
                sourceLanguageCode = "en-US"
            }
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
    /// (see `PersistedSettingsKey`) using `""` as nil's sentinel — same
    /// convention `SettingsView.sourceLanguageBinding` already uses for its
    /// empty-means-auto `TextField`, since `UserDefaults` can't distinguish
    /// "never set" from "explicitly set to nil".
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
    /// (see their declarations) is what keeps this in sync going forward.
    private func restorePersistedSettings() {
        let defaults = Self.defaults
        if let value = defaults.string(forKey: PersistedSettingsKey.transcriptionEngineID) {
            transcriptionEngineID = value
        }
        if let value = defaults.string(forKey: PersistedSettingsKey.translationEngineID) {
            translationEngineID = value
        }
        if let value = defaults.string(forKey: PersistedSettingsKey.sourceLanguageCode) {
            sourceLanguageCode = value.isEmpty ? nil : value
        }
        if let value = defaults.string(forKey: PersistedSettingsKey.targetLanguageCode) {
            targetLanguageCode = value
        }
        if defaults.object(forKey: PersistedSettingsKey.includeSystemAudio) != nil {
            includeSystemAudio = defaults.bool(forKey: PersistedSettingsKey.includeSystemAudio)
        }
        selectedDeviceID = defaults.string(forKey: PersistedSettingsKey.selectedDeviceID)
    }

    public func refreshDevices() {
        inputDevices = [.systemDefault] + MicrophoneCapture.availableDevices()
        if selectedDeviceID == nil || !inputDevices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = inputDevices.first?.id
        }
    }

    // MARK: - Lifecycle

    public func start() async {
        guard !isRunning, !isStopping, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

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
/// ever written into the app's `UserDefaults` domain.
private enum PersistedSettingsKey {
    static let transcriptionEngineID = "org.omnivoice.transcriptionEngineID"
    static let translationEngineID = "org.omnivoice.translationEngineID"
    static let sourceLanguageCode = "org.omnivoice.sourceLanguageCode"
    static let targetLanguageCode = "org.omnivoice.targetLanguageCode"
    static let includeSystemAudio = "org.omnivoice.includeSystemAudio"
    static let selectedDeviceID = "org.omnivoice.selectedDeviceID"
}
