import Foundation

/// Holds microphone audio while the recognizer is still starting, then hands
/// it over in order once there is somewhere to send it — so the microphone can
/// open the moment the key goes down and the first words aren't lost.
/// `submit` runs on the capture queue, `attach` on the main actor; an abandoned buffer is simply released.
final class PendingAudioBuffer: @unchecked Sendable {
    /// Audio kept while waiting (16 kHz mono): anything longer is dropped
    /// rather than growing without bound behind a long asset download.
    static let maxBufferedSamples = 16_000 * 30

    private let lock = NSLock()
    private var chunks: [[Float]] = []
    private var bufferedSamples = 0
    private var sink: (([Float]) -> Void)?

    func submit(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        if let sink {
            sink(samples)
        } else if bufferedSamples + samples.count <= Self.maxBufferedSamples {
            chunks.append(samples)
            bufferedSamples += samples.count
        }
    }

    /// Delivers everything buffered so far, then every later chunk, to `sink`.
    func attach(_ sink: @escaping ([Float]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        for chunk in chunks { sink(chunk) }
        chunks = []
        bufferedSamples = 0
        self.sink = sink
    }
}
