import AVFoundation
import Foundation

/// An already-loaded on-device recognizer lent to a dictation, plus the
/// pause-detection tuning the live recording uses with it.
public struct DictationRecognizerLease {
    public let provider: TranscriptionProvider
    public let vadSilenceSeconds: Double
    public let vadSilenceDBFS: Double
}

/// One push-to-talk dictation: microphone → recognizer → the text to insert.
/// The recognizer is the live transcription's loaded on-device model when
/// there is one to borrow (`borrowRecognizer`), else the system engine. Separate from `RecordingSession` on purpose — no
/// history record, no translation, no panel; it can run while (or without)
/// a live transcription session being open.
@MainActor
public final class DictationSession: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case starting
        case listening
        case finishing
    }

    @Published public private(set) var state: State = .idle
    /// Everything heard so far, updated as the engine revises it.
    @Published public private(set) var previewText = ""
    /// Why the last start failed, for the HUD; cleared by the next start.
    @Published public private(set) var errorMessage: String?
    /// The start failed because the microphone isn't authorized.
    @Published public private(set) var microphonePermissionNeeded = false
    /// This dictation runs on the borrowed on-device model, not the system
    /// engine — for the HUD.
    @Published public private(set) var isUsingLocalModel = false
    /// What a slow start is doing right now ("正在下载语言识别资源…"), for
    /// the HUD; nil once listening.
    @Published public private(set) var statusDetail: String?

    /// How long the microphone keeps running after the user lets go — people
    /// release the key a beat before the last word is out.
    static let trailingAudio: Duration = .milliseconds(250)

    private static let preparingMessage = "正在准备识别引擎…"

    private var transcript = DictationTranscript()
    private var provider: TranscriptionProvider?
    private var vadSegmenter: UtteranceSegmenter?
    private var isRecognizerBorrowed = false
    private var mic: MicrophoneCapture?
    private var startTask: Task<Void, Never>?

    private let borrowRecognizer: @MainActor () -> DictationRecognizerLease?
    private let returnRecognizer: @MainActor () -> Void

    /// - Parameters:
    ///   - borrowRecognizer: asked at each start for a loaded on-device
    ///     recognizer; `nil` means use the system engine.
    ///   - returnRecognizer: called once a borrowed recognizer is released.
    public init(
        borrowRecognizer: @escaping @MainActor () -> DictationRecognizerLease? = { nil },
        returnRecognizer: @escaping @MainActor () -> Void = {}
    ) {
        self.borrowRecognizer = borrowRecognizer
        self.returnRecognizer = returnRecognizer
    }

    public var isActive: Bool { state != .idle }

    /// Starts listening. Returns once the microphone is running (or failed,
    /// leaving `state == .idle` and `errorMessage` set). `finish()`/`cancel()`
    /// called while this is still setting up wait for it.
    public func start(languageCode: String?, deviceID: String?) {
        guard state == .idle else { return }
        state = .starting
        errorMessage = nil
        microphonePermissionNeeded = false
        previewText = ""
        isUsingLocalModel = false
        statusDetail = Self.preparingMessage
        transcript = DictationTranscript()
        startTask = Task { await self.setUp(languageCode: languageCode, deviceID: deviceID) }
    }

    /// Stops listening and returns the dictated text (empty if nothing was
    /// recognized or the start failed).
    public func finish() async -> String {
        await startTask?.value
        startTask = nil
        guard state == .listening else { return "" }
        state = .finishing
        try? await Task.sleep(for: Self.trailingAudio)
        await tearDown()
        // Whatever is still open counts: the engine's last hypothesis is
        // usually all there is when it is stopped before closing a segment.
        let text = transcript.text
        state = .idle
        return text
    }

    /// Stops listening and discards what was heard.
    public func cancel() async {
        // A start still in progress (downloading, opening the microphone)
        // gives up at its next checkpoint instead of running to the end.
        startTask?.cancel()
        await startTask?.value
        startTask = nil
        guard state == .listening else { return }
        state = .finishing
        await tearDown()
        previewText = ""
        state = .idle
    }

    private func setUp(languageCode: String?, deviceID: String?) async {
        let provider: TranscriptionProvider
        let config: TranscriptionConfig
        let segmenter: UtteranceSegmenter?
        if let lease = borrowRecognizer() {
            provider = lease.provider
            isRecognizerBorrowed = true
            isUsingLocalModel = true
            // A local model only commits words as new audio arrives, so a
            // pause has to close the segment, as in a live recording. It
            // can also auto-detect the language, so `languageCode` may be nil.
            let vad = UtteranceSegmenter(
                silenceThresholdSeconds: lease.vadSilenceSeconds, silenceRMSDBFS: Float(lease.vadSilenceDBFS)
            )
            vad.onUtteranceBoundary = { [weak provider] in provider?.notifyUtteranceBoundary() }
            segmenter = vad
            config = TranscriptionConfig(languageCode: languageCode)
        } else {
            let system = SystemTranscriptionProvider()
            system.onInstallingAssets = { [weak self] in
                Task { @MainActor in self?.statusDetail = "正在下载语言识别资源，首次使用需要一点时间…" }
            }
            provider = system
            segmenter = nil
            isUsingLocalModel = false
            // `SpeechTranscriber` needs one concrete locale.
            config = TranscriptionConfig(languageCode: languageCode ?? Locale.current.identifier(.bcp47))
        }
        let transcript = transcript
        provider.onEvent = { [weak self] event in
            _ = transcript.apply(event)
            // Read the text when this runs, not when the event arrived, so a
            // late-running update can't put an older hypothesis back.
            Task { @MainActor in self?.previewText = transcript.text }
        }
        // The recognizer starts while the microphone opens; the audio waits in
        // `pending`, so the recognizer's (slow) start doesn't cost the first words.
        let pending = PendingAudioBuffer()
        let mic = MicrophoneCapture(deviceID: deviceID)
        mic.onBuffer = { pending.submit($0) }
        let providerStart = Task { try await provider.start(config: config) }
        do {
            try mic.start()
        } catch {
            providerStart.cancel()
            _ = try? await providerStart.value
            await provider.stop()
            releaseRecognizer(provider)
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                microphonePermissionNeeded = true
                fail("麦克风权限未授权，请在系统设置中允许访问麦克风")
            } else {
                fail("麦克风启动失败: \(error.localizedDescription)")
            }
            return
        }
        // Speaking now is safe — unless a language download is what we're
        // waiting for, which says so itself.
        if statusDetail == Self.preparingMessage { statusDetail = "请说话…" }
        do {
            // `providerStart` is its own task, so a cancelled dictation has to cancel it.
            try await withTaskCancellationHandler {
                try await providerStart.value
            } onCancel: {
                providerStart.cancel()
            }
        } catch {
            mic.stop()
            releaseRecognizer(provider)
            // Cancelled while starting is the user's own doing, not a failure.
            if Task.isCancelled { abandonStart() } else { fail("听写启动失败: \(error.localizedDescription)") }
            return
        }
        if Task.isCancelled {
            mic.stop()
            await provider.stop()
            releaseRecognizer(provider)
            abandonStart()
            return
        }
        pending.attach { [weak provider, weak segmenter] samples in
            provider?.push(samples: samples)
            segmenter?.submit(samples)
        }
        self.provider = provider
        self.vadSegmenter = segmenter
        self.mic = mic
        statusDetail = nil
        state = .listening
    }

    private func tearDown() async {
        mic?.stop()
        mic = nil
        await provider?.stop()
        if let provider { releaseRecognizer(provider) }
        provider = nil
        vadSegmenter = nil
    }

    /// Detaches from a recognizer: a borrowed one stays loaded for the next
    /// recording and goes back to its owner, an own one is dropped.
    private func releaseRecognizer(_ provider: TranscriptionProvider) {
        provider.onEvent = nil
        if isRecognizerBorrowed {
            isRecognizerBorrowed = false
            returnRecognizer()
        } else {
            provider.unload()
        }
    }

    /// Back to idle after a start the user cancelled — nothing to report.
    private func abandonStart() {
        statusDetail = nil
        previewText = ""
        state = .idle
    }

    private func fail(_ message: String) {
        statusDetail = nil
        errorMessage = message
        state = .idle
    }
}
