import AVFoundation
import Speech

/// Wraps `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26+) for streaming
/// on-device transcription, normalizing its volatile/final callback shape
/// into `TranscriptionEvent` — see that type's doc for the contract.
/// `SpeechTranscriber` already distinguishes volatile (in-progress) from
/// finalized text on its own, so no VAD/sentence-boundary heuristic is
/// needed here; a finalized result IS the segment boundary, delivered as
/// `.segmentClosed(finalAppend: fullText)` since nothing was ever reported
/// via `.appended` for this engine. `notifyUtteranceBoundary()` is therefore
/// left at the protocol's no-op default.
///
/// Ported from `mac-poc-hybrid`'s `Recognition/AppleSpeechRecognizer.swift`.
public final class SystemTranscriptionProvider: TranscriptionProvider {
    public var onEvent: ((TranscriptionEvent) -> Void)?
    /// Called when `start(config:)` has to download the language's on-device
    /// recognition assets first — the one slow step, worth telling the user
    /// about. Called on the main actor, before the download begins.
    public var onInstallingAssets: (() -> Void)?

    /// Called once the recognition assets are in place — right away when
    /// they already were — so audio sent from here on is analyzed, not
    /// merely buffered behind a download. Main actor.
    public var onAssetsReady: (() -> Void)?

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?

    /// Guards every field `push(samples:)` touches. `push` runs on
    /// whatever background queue `AudioMixer` calls it from (never hopped to
    /// the main actor — see `TranscriptionProvider`'s doc), while
    /// `start(config:)`/`stop()` run on the main actor, so without this lock
    /// `stop()` nil-ing these out and `push` reading/mutating them can run
    /// concurrently on two different threads — exactly the race a review of
    /// this file's first version caught (`stop()` and an in-flight `push`
    /// touching `resampler`/`inputContinuation` with no synchronization at
    /// all).
    ///
    /// `nonisolated(unsafe)` on the fields below is what it says: unsafe on
    /// its own. It's only correct here because every read/write of them,
    /// everywhere in this file, happens inside `audioQueue.sync { ... }` —
    /// the class itself is inferred `@MainActor` (it conforms to
    /// `TranscriptionProvider`, a `@MainActor` protocol), so without this
    /// annotation these fields would be main-actor-isolated too, and
    /// `nonisolated func push` (which must run on the calling audio thread,
    /// not hop to the main actor per buffer) couldn't touch them at all.
    private let audioQueue = DispatchQueue(label: "org.hdcola.omnivoice.systemtranscription.audio")
    private nonisolated(unsafe) var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private nonisolated(unsafe) var analyzerFormat: AVAudioFormat?
    /// Resamples each incoming mixed-audio chunk (mono Float32 at
    /// `sourceSampleRate`, fixed at 16kHz — the format `AudioMixer` emits)
    /// into `analyzerFormat` right before wrapping it as an `AnalyzerInput`.
    private nonisolated(unsafe) var resampler: AVAudioConverter?
    private nonisolated(unsafe) var resamplerSourceFormat: AVAudioFormat?
    private nonisolated static let sourceSampleRate: Double = 16000

    public init() {}

    /// Installs the on-device recognition assets for `languageCode` ahead of
    /// time, so the first `start(config:)` for it doesn't wait on the
    /// download. A no-op once they are installed.
    public static func prepareAssets(languageCode: String, onInstalling: (() -> Void)? = nil) async throws {
        let locale = try await resolveSupportedLocale(Locale(identifier: languageCode))
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: []
        )
        try await ensureModelInstalled(for: transcriber, locale: locale, onInstalling: onInstalling)
        _ = try await analyzerFormat(for: transcriber, locale: locale)
    }

    public func loadModel() async throws {
        // No separate "load" phase — the on-device asset (if missing) is
        // installed lazily in `start(config:)`.
    }

    public func unload() {}

    public func start(config: TranscriptionConfig) async throws {
        guard let languageCode = config.languageCode else {
            // `SpeechTranscriber` requires one concrete locale per session —
            // unlike a `.model` provider, there is no auto-detect option here.
            throw ProviderError.localeNotSupported
        }
        let locale = try await Self.resolveSupportedLocale(Locale(identifier: languageCode))

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        try await Self.ensureModelInstalled(for: transcriber, locale: locale, onInstalling: onInstallingAssets)
        onAssetsReady?()

        let format = try await Self.analyzerFormat(for: transcriber, locale: locale)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        audioQueue.sync {
            analyzerFormat = format
            inputContinuation = continuation
            // A previous run's resampler was built against that run's
            // `analyzerFormat`; don't carry it into this one.
            resampler = nil
            resamplerSourceFormat = nil
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            // Assets removed or damaged since they were checked: look again next time.
            Self.installedLocaleIDs.remove(locale.identifier(.bcp47))
            throw error
        }

        self.transcriber = transcriber
        self.analyzer = analyzer

        resultsTask = Task { [weak self] in
            guard let self, let transcriber = self.transcriber else { return }
            _ = try? await {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.onEvent?(.segmentClosed(finalAppend: text))
                    } else {
                        self.onEvent?(.revised(text))
                    }
                }
            }()
        }
    }

    public nonisolated func push(samples: [Float]) {
        audioQueue.sync {
            guard let analyzerFormat, let continuation = inputContinuation else { return }
            guard let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.sourceSampleRate,
                channels: 1,
                interleaved: false
            ) else { return }

            if resampler == nil || resamplerSourceFormat != sourceFormat {
                resampler = AVAudioConverter(from: sourceFormat, to: analyzerFormat)
                resamplerSourceFormat = sourceFormat
            }
            guard let resampler else { return }

            guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
                return
            }
            sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
            guard let channelData = sourceBuffer.floatChannelData else { return }
            samples.withUnsafeBufferPointer { pointer in
                guard let baseAddress = pointer.baseAddress else { return }
                channelData[0].update(from: baseAddress, count: samples.count)
            }

            let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 32
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }

            var consumed = false
            var conversionError: NSError?
            let status = resampler.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }
            guard status != .error, conversionError == nil, outputBuffer.frameLength > 0 else { return }

            continuation.yield(AnalyzerInput(buffer: outputBuffer))
        }
    }

    public func stop() async {
        audioQueue.sync {
            inputContinuation?.finish()
            inputContinuation = nil
            analyzerFormat = nil
            resampler = nil
            resamplerSourceFormat = nil
        }
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
    }

    /// The supported locale `requested` stands for — see `matchLocale(_:in:)`.
    private static func resolveSupportedLocale(_ requested: Locale) async throws -> Locale {
        let key = requested.identifier(.bcp47)
        if let cached = resolvedLocales[key] { return cached }
        guard let match = matchLocale(requested, in: Array(await SpeechTranscriber.supportedLocales)) else {
            throw ProviderError.localeNotSupported
        }
        resolvedLocales[key] = match
        return match
    }

    /// Picks which of `supported` serves `requested`: the same BCP-47 tag,
    /// else the same language and region (the system's own "zh-Hans-CN" is
    /// listed as "zh-CN"), else the same language and writing system (a
    /// Singapore Chinese "zh-Hans-SG" gets Simplified zh-CN, not the
    /// Traditional zh-TW that happens to be listed first), else the same
    /// language alone (en-AU → en-US).
    nonisolated static func matchLocale(_ requested: Locale, in supported: [Locale]) -> Locale? {
        let language = requested.language.languageCode
        let script = likelyScript(of: requested)
        return supported.first { $0.identifier(.bcp47) == requested.identifier(.bcp47) }
            ?? supported.first { $0.language.languageCode == language && $0.region == requested.region }
            ?? supported.first { $0.language.languageCode == language && likelyScript(of: $0) == script }
            ?? supported.first { $0.language.languageCode == language }
    }

    /// The writing system a locale implies — "zh-CN" has no script of its
    /// own in its tag, but is Simplified (Hans) once likely subtags are added.
    private nonisolated static func likelyScript(of locale: Locale) -> Locale.Script? {
        Locale.Language(identifier: locale.language.maximalIdentifier).script
    }

    /// What a start would otherwise look up again every time: the locale a
    /// requested language resolves to, the locales whose assets are known to
    /// be installed, and each locale's analyzer audio format.
    private static var resolvedLocales: [String: Locale] = [:]
    private static var installedLocaleIDs: Set<String> = []
    private static var analyzerFormats: [String: AVAudioFormat] = [:]

    private static func analyzerFormat(for transcriber: SpeechTranscriber, locale: Locale) async throws -> AVAudioFormat {
        let key = locale.identifier(.bcp47)
        if let cached = analyzerFormats[key] { return cached }
        guard let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ProviderError.notImplemented("SpeechAnalyzer 无可用音频格式")
        }
        analyzerFormats[key] = best
        return best
    }

    private static func ensureModelInstalled(
        for transcriber: SpeechTranscriber, locale: Locale, onInstalling: (() -> Void)?
    ) async throws {
        let id = locale.identifier(.bcp47)
        if installedLocaleIDs.contains(id) { return }
        let installed = await SpeechTranscriber.installedLocales
        if !installed.contains(where: { $0.identifier(.bcp47) == id }),
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onInstalling?()
            try await request.downloadAndInstall()
        }
        installedLocaleIDs.insert(id)
    }
}
