import AVFoundation

enum CaptureError: LocalizedError {
    case noDevice
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noDevice: return "找不到可用的麦克风设备"
        case .cannotAddInput: return "无法添加麦克风输入到采集会话"
        case .cannotAddOutput: return "无法添加音频输出到采集会话"
        }
    }
}

/// Captures a specific microphone via `AVCaptureSession`, converts every
/// buffer to mono 16 kHz Float32 PCM, and hands it off through `onBuffer`.
/// Ported unchanged from `mac-poc-hybrid`'s `Audio/MicrophoneCapture.swift`.
final class MicrophoneCapture: NSObject {
    var onBuffer: (([Float]) -> Void)?

    private let deviceID: String?
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private let queue = DispatchQueue(label: "org.hdcola.omnivoice.mic")
    /// `startRunning()`/`stopRunning()` block until the hardware answers, so
    /// they run here, in order, instead of on the main actor. One queue for
    /// every instance, so a quick re-press never starts a new session while
    /// the previous one is still stopping.
    private static let controlQueue = DispatchQueue(label: "org.hdcola.omnivoice.mic.control")
    private let converter = PCMConverter(targetSampleRate: 16000, targetChannels: 1)

    init(deviceID: String?) {
        self.deviceID = deviceID
    }

    static func availableDevices() -> [AudioInputDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices.map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    func start() throws {
        let session = AVCaptureSession()

        let device: AVCaptureDevice?
        if let deviceID, deviceID != AudioInputDevice.systemDefaultID, let match = AVCaptureDevice(uniqueID: deviceID) {
            device = match
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }
        guard let device else { throw CaptureError.noDevice }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureError.cannotAddOutput }
        session.addOutput(output)

        self.session = session
        self.output = output
        Self.controlQueue.async { session.startRunning() }
    }

    func stop() {
        // The session keeps delivering frames until `stopRunning()` lands.
        output?.setSampleBufferDelegate(nil, queue: nil)
        if let session { Self.controlQueue.async { session.stopRunning() } }
        session = nil
        output = nil
    }
}

extension MicrophoneCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let samples = converter.convert(sampleBuffer: sampleBuffer) else { return }
        onBuffer?(samples)
    }
}
