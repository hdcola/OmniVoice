import AVFoundation
import ScreenCaptureKit

enum SystemAudioError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "找不到可捕获的屏幕/显示器,无法建立系统音频采集"
        }
    }
}

/// Captures the machine's system/output audio via ScreenCaptureKit
/// (audio-only content filter) and converts it to mono 16 kHz Float32 PCM.
/// First use triggers the macOS "Screen Recording" privacy prompt — that is
/// currently the only public API surface for system-audio capture. Cannot
/// capture FaceTime/Continuity call audio — same limitation the POC noted.
/// Ported unchanged from `mac-poc-hybrid`'s `Audio/SystemAudioCapture.swift`.
final class SystemAudioCapture: NSObject {
    var onBuffer: (([Float]) -> Void)?

    private var stream: SCStream?
    private let converter = PCMConverter(targetSampleRate: 16000, targetChannels: 1)
    private let queue = DispatchQueue(label: "org.hdcola.omnivoice.systemaudio")

    @MainActor
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw SystemAudioError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        // SCStream still requires a (minimal) video track even when only the
        // audio output is consumed; keep it as small/infrequent as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    @MainActor
    func stop() {
        guard let stream else { return }
        self.stream = nil
        Task { @MainActor in
            try? await stream.stopCapture()
        }
    }
}

extension SystemAudioCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let samples = converter.convert(sampleBuffer: sampleBuffer) else { return }
        onBuffer?(samples)
    }
}
