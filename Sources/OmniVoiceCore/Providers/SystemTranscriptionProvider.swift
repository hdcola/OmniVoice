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
    private let audioQueue = DispatchQueue(label: "org.omnivoice.systemtranscription.audio")
    private nonisolated(unsafe) var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private nonisolated(unsafe) var analyzerFormat: AVAudioFormat?
    /// Resamples each incoming mixed-audio chunk (mono Float32 at
    /// `sourceSampleRate`, fixed at 16kHz — the format `AudioMixer` emits)
    /// into `analyzerFormat` right before wrapping it as an `AnalyzerInput`.
    private nonisolated(unsafe) var resampler: AVAudioConverter?
    private nonisolated(unsafe) var resamplerSourceFormat: AVAudioFormat?
    private nonisolated static let sourceSampleRate: Double = 16000

    public init() {}

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
        let locale = Locale(identifier: languageCode)

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        try await Self.ensureModelInstalled(for: transcriber, locale: locale)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ProviderError.notImplemented("SpeechAnalyzer 无可用音频格式")
        }

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
        try await analyzer.start(inputSequence: stream)

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

    private static func ensureModelInstalled(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw ProviderError.localeNotSupported
        }
        let installed = await SpeechTranscriber.installedLocales
        guard !installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }
}
