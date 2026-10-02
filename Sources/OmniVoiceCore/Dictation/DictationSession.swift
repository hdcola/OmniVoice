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

    /// How long the microphone keeps running after the user lets go — people
    /// release the key a beat before the last word is out.
    static let trailingAudio: Duration = .milliseconds(250)

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
            provider = SystemTranscriptionProvider()
            segmenter = nil
            isUsingLocalModel = false
            // `SpeechTranscriber` needs one concrete locale.
            config = TranscriptionConfig(languageCode: languageCode ?? Locale.current.identifier(.bcp47))
        }
        let transcript = transcript
        provider.onEvent = { [weak self] event in
            let text = transcript.apply(event)
            Task { @MainActor in self?.previewText = text }
        }
        do {
            try await provider.start(config: config)
        } catch {
            releaseRecognizer(provider)
            fail("听写启动失败: \(error.localizedDescription)")
            return
        }

        let mic = MicrophoneCapture(deviceID: deviceID)
        mic.onBuffer = { [weak provider, weak segmenter] samples in
            provider?.push(samples: samples)
            segmenter?.submit(samples)
        }
        do {
            try mic.start()
        } catch {
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
        self.provider = provider
        self.vadSegmenter = segmenter
        self.mic = mic
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

    private func fail(_ message: String) {
        errorMessage = message
        state = .idle
    }
}
