import Combine
import Foundation
import Translation

/// Engine IDs the selection translation panel can use — the two one-shot
/// engines from `ProviderCatalog.translationEngines`. T3PO is deliberately
/// not offered: its WAIT/TRANS streaming design and 200-token output cap
/// (see `InProcessTranslator`) are built for live speech, not for
/// translating a finished paragraph in one go.
public enum SelectionTranslationEngine {
    public static let system = "system.translation"
    public static let hymt15 = "model.hymt15"
    /// Not an engine itself — "use whatever the recording uses", resolved
    /// per translation by `SelectionTranslator.effectiveEngineID`. The
    /// default, so the panel and the transcript agree out of the box.
    public static let followRecording = "follow.recording"

    public static var all: [EngineDescriptor] {
        ProviderCatalog.translationEngines.filter { $0.id == system || $0.id == hymt15 }
    }

    public static func displayName(for id: String) -> String {
        all.first { $0.id == id }?.displayName ?? id
    }
}

/// State and orchestration behind the selection translation panel (⌥A
/// select-to-translate, ⌥S screenshot OCR translation) — modeled on Cida's
/// panel, restricted to this app's local engines.
///
/// Deliberately independent of `RecordingSession`: the panel works whether
/// or not a recording is running, and never touches the recording's
/// providers, transcript, or HY-MT1.5 context history. The HY-MT1.5
/// weights themselves *are* shared, though — both sides borrow the same
/// loaded `HYMT15Translator` from `HYMT15ModelPool`, so using the panel
/// during a HY-MT1.5 recording costs no extra memory.
///
/// Translation runs paragraph by paragraph (`SelectionTextChunker`) and
/// `resultText` grows as each one finishes — the closest thing to Cida's
/// streamed output these non-streaming engines allow.
@MainActor
public final class SelectionTranslator: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case loadingModel
        case translating
        case completed
        case failed(String)
    }

    /// The text in the panel's editable source pane.
    @Published public var sourceText: String = ""
    @Published public private(set) var resultText: String = ""
    @Published public private(set) var phase: Phase = .idle
    /// `SelectionLanguageDirection.detectLanguageCode(of:...)`'s answer for
    /// the text last translated — nil before the first translation or when
    /// detection gave up.
    @Published public private(set) var detectedSourceCode: String?
    /// Where the last translation went (the automatic direction, unless
    /// `targetOverrideCode` said otherwise).
    @Published public private(set) var targetCode: String
    /// Picked from the panel's target menu — wins over the automatic
    /// direction until the next selection is brought in (`load(_:)`).
    @Published public var targetOverrideCode: String?
    /// The source text `resultText` was translated from, so the panel can
    /// flag a result as stale once the user edits the source.
    @Published public private(set) var translatedSourceText: String?
    /// Bumped each time a translation runs to its end (not when it is
    /// stopped or fails) — what "read the translation aloud once it's
    /// done" listens for.
    @Published public private(set) var finishedTranslationCount = 0

    /// A `SelectionTranslationEngine` ID — `followRecording` or one of `all`.
    @Published public var engineID: String {
        didSet { defaults.set(engineID, forKey: PersistedSelectionKey.engineID) }
    }
    /// The user's languages, shared with the recording and voice input.
    public let languages: LanguagePreferences
    private var languagesObserver: AnyCancellable?
    /// "我的语言" — see `SelectionLanguageDirection`'s doc.
    public var myLanguageCode: String {
        get { languages.myLanguageCode }
        set { languages.myLanguageCode = newValue }
    }
    /// "外语" — where text already in `myLanguageCode` is translated to.
    public var foreignLanguageCode: String {
        get { languages.foreignLanguageCode }
        set { languages.foreignLanguageCode = newValue }
    }

    /// What `SelectionTranslationView`'s `.translationTask` watches —
    /// `TranslationSession` can only be vended inside a SwiftUI view (same
    /// constraint `SystemTranslationProvider`'s doc describes), so a
    /// system-engine translation is started by publishing a configuration
    /// here, and the view hands its session back through
    /// `runPendingSystemJob(using:)`.
    @Published public private(set) var systemTranslationConfiguration: TranslationSession.Configuration?

    public var isBusy: Bool { phase == .loadingModel || phase == .translating }

    /// True once `sourceText` no longer matches what `resultText` was
    /// translated from.
    public var isResultStale: Bool {
        guard let translatedSourceText, !resultText.isEmpty else { return false }
        return translatedSourceText != sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Job {
        let generation: Int
        let pieces: [SelectionTextPiece]
        let sourceCode: String?
        let targetCode: String
    }

    private let defaults: UserDefaults
    private let modelBackend: SelectionModelTranslating
    private let modelURLProvider: () -> URL?
    private let recordingEngineID: () -> String?
    /// Bumped by every `translate()`/`cancel()` — a job that finds it
    /// changed stops without touching the published state.
    private var generation = 0
    private var modelTask: Task<Void, Never>?
    private var pendingSystemJob: Job?

    /// `preferredModelVariantID` and `recordingEngineID` are asked on every
    /// translation — the app passes the recording's selected translation
    /// variant and engine, so the panel uses the same HY-MT1.5 quantization
    /// when both are HY-MT1.5, and so `followRecording` tracks the
    /// recording's engine as it changes.
    public convenience init(
        modelDownloadManager: ModelDownloadManager,
        preferredModelVariantID: @escaping () -> String? = { nil },
        recordingEngineID: @escaping () -> String? = { nil },
        languages: LanguagePreferences? = nil
    ) {
        self.init(
            defaults: .standard,
            languages: languages,
            modelBackend: SelectionModelBackend(),
            recordingEngineID: recordingEngineID,
            modelURLProvider: {
                let variants = ProviderCatalog.modelVariants(forEngineID: SelectionTranslationEngine.hymt15)
                    .filter { modelDownloadManager.isDownloaded($0) }
                let preferred = variants.first { $0.id == preferredModelVariantID() } ?? variants.first
                return preferred.map { modelDownloadManager.localURL(for: $0) }
            }
        )
    }

    /// Internal — tests inject an in-memory `UserDefaults`, a fake model
    /// backend, and a fixed model URL instead of real downloaded weights.
    init(
        defaults: UserDefaults, languages: LanguagePreferences? = nil, modelBackend: SelectionModelTranslating,
        recordingEngineID: @escaping () -> String? = { nil }, modelURLProvider: @escaping () -> URL?
    ) {
        self.defaults = defaults
        self.modelBackend = modelBackend
        self.recordingEngineID = recordingEngineID
        self.modelURLProvider = modelURLProvider
        let storedEngine = defaults.string(forKey: PersistedSelectionKey.engineID)
        let isKnown = storedEngine == SelectionTranslationEngine.followRecording
            || SelectionTranslationEngine.all.contains { $0.id == storedEngine }
        engineID = isKnown ? storedEngine! : SelectionTranslationEngine.followRecording
        let languages = languages ?? LanguagePreferences(defaults: defaults)
        self.languages = languages
        let mine = languages.myLanguageCode
        targetCode = mine
        languagesObserver = languages.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Whether HY-MT1.5 weights are downloaded — the settings tab greys the
    /// engine out otherwise.
    public var isModelEngineAvailable: Bool { modelURLProvider() != nil }

    /// The engine a translation started now would actually use —
    /// `engineID` itself, unless that's `followRecording`: then the
    /// recording's engine when it's one the panel can run, and for T3PO
    /// (see `SelectionTranslationEngine`'s doc for why the panel never uses
    /// it) HY-MT1.5 when downloaded — the closer match, being a local model
    /// too — else the system engine.
    public var effectiveEngineID: String {
        guard engineID == SelectionTranslationEngine.followRecording else { return engineID }
        switch recordingEngineID() {
        case SelectionTranslationEngine.system:
            return SelectionTranslationEngine.system
        case SelectionTranslationEngine.hymt15:
            return SelectionTranslationEngine.hymt15
        default:
            return isModelEngineAvailable ? SelectionTranslationEngine.hymt15 : SelectionTranslationEngine.system
        }
    }

    /// Brings a new selection/OCR result into the source pane and
    /// translates it. The same text as last time keeps the existing result
    /// instead of translating again (Cida's "same selection is a no-op"), so
    /// re-summoning the panel over an unchanged selection is instant.
    public func load(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed == translatedSourceText, trimmed == sourceText, phase == .completed || isBusy { return }
        sourceText = trimmed
        targetOverrideCode = nil
        translate()
    }

    /// Translates `sourceText` from scratch, cancelling whatever was running.
    public func translate() {
        cancel()
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let detected = SelectionLanguageDirection.detectLanguageCode(
            of: text, myLanguageCode: myLanguageCode, foreignLanguageCode: foreignLanguageCode
        )
        let target = targetOverrideCode ?? SelectionLanguageDirection.targetCode(
            forDetected: detected, myLanguageCode: myLanguageCode, foreignLanguageCode: foreignLanguageCode
        )
        detectedSourceCode = detected
        targetCode = target
        translatedSourceText = text
        resultText = ""

        let job = Job(
            generation: generation, pieces: SelectionTextChunker.pieces(of: text),
            sourceCode: detected, targetCode: target
        )
        if effectiveEngineID == SelectionTranslationEngine.hymt15 {
            startModelJob(job)
        } else {
            startSystemJob(job)
        }
    }

    /// Stops the running translation, keeping whatever already finished.
    public func cancel() {
        generation += 1
        modelTask?.cancel()
        modelTask = nil
        pendingSystemJob = nil
        if isBusy {
            phase = resultText.isEmpty ? .idle : .completed
        }
    }

    /// Called by `SelectionTranslationView`'s `.translationTask` with its
    /// session's `translate` — see `systemTranslationConfiguration`'s doc.
    public func runPendingSystemJob(using translate: @escaping (String) async throws -> String) async {
        guard let job = pendingSystemJob else { return }
        pendingSystemJob = nil
        await run(job, translate: translate)
    }

    /// Synchronously releases HY-MT1.5 before exit — see
    /// `AppDelegate.applicationWillTerminate`.
    public func unloadModelBeforeQuit() {
        modelBackend.unload()
    }

    private func startModelJob(_ job: Job) {
        guard ModelLanguageMapping.isNativelyTranslatableByLocalModel(code: job.targetCode) else {
            let name = LanguageCatalog.displayName(for: job.targetCode)
            phase = .failed("HY-MT1.5 暂时只能译成中文、英语、日语或韩语，无法译成\(name)。可以在设置里改用系统翻译。")
            return
        }
        guard let modelURL = modelURLProvider() else {
            phase = .failed("HY-MT1.5 模型尚未下载。请在「设置 → 模型库」中下载，或改用系统翻译。")
            return
        }
        let target = ModelLanguageMapping.hyMT15TargetLanguage(forCode: job.targetCode)
        let sourceIsChinese = job.sourceCode.map { SelectionLanguageDirection.isSameLanguage($0, "zh") } ?? false
        let backend = modelBackend
        phase = backend.isLoaded(modelURL: modelURL) ? .translating : .loadingModel
        modelTask = Task { [weak self] in
            await self?.run(job) { text in
                let output = try await backend.translate(
                    text, targetLanguage: target, sourceIsChinese: sourceIsChinese, modelURL: modelURL
                )
                await MainActor.run { [weak self] in
                    if self?.phase == .loadingModel, self?.generation == job.generation {
                        self?.phase = .translating
                    }
                }
                return output
            }
        }
    }

    private func startSystemJob(_ job: Job) {
        phase = .translating
        pendingSystemJob = job
        let source = job.sourceCode.map { Locale.Language(identifier: $0) }
        let target = Locale.Language(identifier: job.targetCode)
        if var configuration = systemTranslationConfiguration,
           configuration.source == source, configuration.target == target {
            // Same language pair — `invalidate()` re-runs the view's
            // `.translationTask` without building a new session.
            configuration.invalidate()
            systemTranslationConfiguration = configuration
        } else {
            systemTranslationConfiguration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    private func run(_ job: Job, translate: (String) async throws -> String) async {
        var output = ""
        for piece in job.pieces {
            guard job.generation == generation, !Task.isCancelled else { return }
            switch piece {
            case .verbatim(let text):
                output += text
            case .softBreak:
                if !SelectionLanguageDirection.joinsWithoutSpaces(job.targetCode) { output += " " }
            case .text(let text):
                do {
                    output += try await translate(text)
                } catch {
                    guard job.generation == generation, !(error is CancellationError) else { return }
                    phase = .failed("翻译失败：\(error.localizedDescription)")
                    return
                }
                guard job.generation == generation else { return }
                resultText = output
            }
        }
        guard job.generation == generation else { return }
        resultText = output.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .completed
        finishedTranslationCount += 1
    }
}

/// The HY-MT1.5 side of `SelectionTranslator`, behind a protocol so tests
/// can run the panel's orchestration without real weights.
protocol SelectionModelTranslating: AnyObject {
    @MainActor func isLoaded(modelURL: URL) -> Bool
    @MainActor func translate(
        _ text: String, targetLanguage: HYMT15TargetLanguage, sourceIsChinese: Bool, modelURL: URL
    ) async throws -> String
    @MainActor func unload()
}

/// The selection panel's hold on a shared `HYMT15Translator` from
/// `HYMT15ModelPool` — taken on first use (instant when a recording already
/// has the same weights loaded), let go after `idleTimeout` without a
/// translation, so the panel alone never keeps the weights in memory for
/// long.
@MainActor
final class SelectionModelBackend: SelectionModelTranslating {
    static let idleTimeout: Duration = .seconds(300)

    private let pool: HYMT15ModelPool
    private var held: (url: URL, translator: HYMT15Translator)?
    /// The in-flight acquisition, shared so two translations started back
    /// to back don't take two holds.
    private var acquiring: (url: URL, task: Task<HYMT15Translator, Error>)?
    private var idleReleaseTask: Task<Void, Never>?

    /// Not a `= .shared` default argument — see `RecordingSession.init`'s
    /// note on main-actor statics in default arguments.
    init(pool: HYMT15ModelPool? = nil) {
        self.pool = pool ?? .shared
    }

    func isLoaded(modelURL: URL) -> Bool {
        held?.url == modelURL || pool.isLoaded(modelURL: modelURL)
    }

    func translate(
        _ text: String, targetLanguage: HYMT15TargetLanguage, sourceIsChinese: Bool, modelURL: URL
    ) async throws -> String {
        idleReleaseTask?.cancel()
        defer { scheduleIdleRelease() }
        let translator = try await translator(for: modelURL)
        return try await translator.translateText(text, targetLanguage: targetLanguage, sourceIsChinese: sourceIsChinese)
    }

    func unload() {
        idleReleaseTask?.cancel()
        acquiring = nil
        if let held {
            self.held = nil
            pool.release(held.translator)
        }
    }

    /// The hold is recorded in `held` *inside* the acquiring task, so every
    /// caller waiting on it — not just the one that started it — resumes
    /// with the hold already in place, and exactly one hold exists no matter
    /// which resumes first. `acquiring` is cleared the same way on failure,
    /// so a failed load (a corrupt file, say) is retried by the next
    /// translation instead of replaying the cached failure forever.
    private func translator(for url: URL) async throws -> HYMT15Translator {
        if let held, held.url == url { return held.translator }
        if let acquiring, acquiring.url == url { return try await acquiring.task.value }
        unload()
        let pool = pool
        let task = Task { [weak self] () throws -> HYMT15Translator in
            do {
                let translator = try await pool.acquire(modelURL: url)
                guard let self, self.acquiring?.url == url else {
                    // Released (or switched to other weights) while this
                    // was loading — give the hold straight back.
                    pool.release(translator)
                    throw CancellationError()
                }
                self.acquiring = nil
                self.held = (url, translator)
                return translator
            } catch {
                if self?.acquiring?.url == url { self?.acquiring = nil }
                throw error
            }
        }
        acquiring = (url, task)
        return try await task.value
    }

    private func scheduleIdleRelease() {
        idleReleaseTask?.cancel()
        idleReleaseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }
}

/// Same `org.hdcola.omnivoice.*` namespacing as `PersistedSettingsKey`.
enum PersistedSelectionKey {
    static let engineID = "org.hdcola.omnivoice.selection.engineID"
    static let myLanguageCode = "org.hdcola.omnivoice.selection.myLanguageCode"
    static let foreignLanguageCode = "org.hdcola.omnivoice.selection.foreignLanguageCode"
}
