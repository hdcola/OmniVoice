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
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?

    /// Resamples each incoming mixed-audio chunk (mono Float32 at
    /// `sourceSampleRate`, fixed at 16kHz — the format `AudioMixer` emits)
    /// into `analyzerFormat` right before wrapping it as an `AnalyzerInput`.
    private var resampler: AVAudioConverter?
    private var resamplerSourceFormat: AVAudioFormat?
    private static let sourceSampleRate: Double = 16000

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
        analyzerFormat = format

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

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

    public func push(samples: [Float]) {
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

    public func stop() async {
        inputContinuation?.finish()
        inputContinuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        analyzerFormat = nil
        resampler = nil
        resamplerSourceFormat = nil
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
