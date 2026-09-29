import Foundation

/// Combines the microphone stream with an optional system-audio stream into
/// one mono 16 kHz Float32 PCM stream, emitted as `[Float]` chunks ready to
/// hand to any `TranscriptionProvider.push(samples:)`.
///
/// The microphone callback drives the output cadence ("master clock"); when
/// system audio is included, an equal number of samples is pulled from a
/// small bounded system-audio buffer (zero-filled if not enough has arrived
/// yet) and summed in with clipping. Simple POC-grade mixer, not a
/// sample-accurate one — ported unchanged from `mac-poc-hybrid`'s
/// `Audio/AudioMixer.swift`.
///
/// `micEnabled: false` (a "无" mic selection — system-audio-only recording,
/// see `AudioInputDevice.none`'s doc) flips which stream drives the clock:
/// `submitMic` is simply never called by the caller in that mode, and
/// `submitSystemAudio` emits its samples directly and immediately instead of
/// buffering them for a mic callback that will never come.
final class AudioMixer {
    var onPCMChunk: (([Float]) -> Void)?
    /// Peak level (0...1) of each emitted (post-mix) chunk, for a UI meter.
    var onLevel: ((Float) -> Void)?

    private let includeSystemAudio: Bool
    private let micEnabled: Bool
    private let queue = DispatchQueue(label: "org.omnivoice.mixer")
    private var systemBuffer: [Float] = []
    private let maxSystemBufferSamples = 16000 * 2 // ~2s of slack at 16kHz

    init(includeSystemAudio: Bool, micEnabled: Bool = true) {
        self.includeSystemAudio = includeSystemAudio
        self.micEnabled = micEnabled
    }

    func submitMic(_ samples: [Float]) {
        queue.async {
            // Defensive, not load-bearing today — `RecordingSession.start()`
            // never constructs/wires a `MicrophoneCapture` at all when
            // `micEnabled` is `false`, so nothing currently calls this in
            // that mode. Guards it anyway so this class's own invariant
            // ("no mic audio is ever mixed in when disabled") holds even if
            // a future caller got that wiring wrong.
            guard self.micEnabled else { return }
            guard self.includeSystemAudio else {
                self.emit(samples)
                return
            }
            let available = min(self.systemBuffer.count, samples.count)
            var mixed = [Float](repeating: 0, count: samples.count)
            for i in 0..<samples.count {
                let micSample = samples[i]
                let sysSample = i < available ? self.systemBuffer[i] : 0
                mixed[i] = max(-1, min(1, micSample + sysSample))
            }
            if available > 0 {
                self.systemBuffer.removeFirst(available)
            }
            self.emit(mixed)
        }
    }

    func submitSystemAudio(_ samples: [Float]) {
        guard includeSystemAudio else { return }
        queue.async {
            guard self.micEnabled else {
                // No mic ever calls `submitMic` in this mode — system audio
                // itself is the master clock, emitted as it arrives rather
                // than buffered for a mic callback that will never come.
                self.emit(samples)
                return
            }
            self.systemBuffer.append(contentsOf: samples)
            if self.systemBuffer.count > self.maxSystemBufferSamples {
                self.systemBuffer.removeFirst(self.systemBuffer.count - self.maxSystemBufferSamples)
            }
        }
    }

    private func emit(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        onPCMChunk?(samples)
        onLevel?(Self.peakLevel(samples))
    }

    /// Converts peak amplitude to a 0...1 level on a dBFS scale rather than a
    /// linear one — normal speech barely moves a linear peak meter.
    private static func peakLevel(_ samples: [Float]) -> Float {
        var peak: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
        }
        guard peak > 0 else { return 0 }

        let dB = 20 * log10(peak)
        let minDB: Float = -45 // quiet room / silence floor
        let normalized = (dB - minDB) / -minDB
        return max(0, min(1, normalized))
    }
}
