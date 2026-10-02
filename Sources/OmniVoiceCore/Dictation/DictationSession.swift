import AVFoundation
import Foundation

/// One push-to-talk dictation: microphone → `SystemTranscriptionProvider` →
/// the text to insert. Separate from `RecordingSession` on purpose — no
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

    /// How long the microphone keeps running after the user lets go — people
    /// release the key a beat before the last word is out.
    static let trailingAudio: Duration = .milliseconds(250)

    private var assembler = DictationTextAssembler()
    private var provider: SystemTranscriptionProvider?
    private var mic: MicrophoneCapture?
    private var startTask: Task<Void, Never>?

    public init() {}

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
        assembler = DictationTextAssembler()
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
        let text = assembler.text
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
        let provider = SystemTranscriptionProvider()
        provider.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        do {
            try await provider.start(config: TranscriptionConfig(languageCode: languageCode ?? Locale.current.identifier(.bcp47)))
        } catch {
            fail("听写启动失败: \(error.localizedDescription)")
            return
        }

        let mic = MicrophoneCapture(deviceID: deviceID)
        mic.onBuffer = { [weak provider] samples in provider?.push(samples: samples) }
        do {
            try mic.start()
        } catch {
            await provider.stop()
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                microphonePermissionNeeded = true
                fail("麦克风权限未授权，请在系统设置中允许访问麦克风")
            } else {
                fail("麦克风启动失败: \(error.localizedDescription)")
            }
            return
        }
        self.provider = provider
        self.mic = mic
        state = .listening
    }

    private func handle(_ event: TranscriptionEvent) {
        assembler.apply(event)
        previewText = assembler.text
    }

    private func tearDown() async {
        mic?.stop()
        mic = nil
        await provider?.stop()
        provider = nil
        // Events the engine flushed while stopping are queued on the main
        // actor behind this call; let them land before the text is read.
        await Task.yield()
    }

    private func fail(_ message: String) {
        errorMessage = message
        state = .idle
    }
}
