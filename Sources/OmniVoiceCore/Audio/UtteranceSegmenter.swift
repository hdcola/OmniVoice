import Foundation

/// Simple energy-based voice-activity detector that signals "this utterance
/// is over" after a sustained pause following detected speech.
///
/// Only meaningful for `.model`-kind ASR providers (e.g. R2T2's
/// Longest-Stable-Prefix streaming, which only commits a word once *new*
/// incoming audio proves it won't change anymore) — `RecordingSession` runs
/// this unconditionally and forwards boundaries via
/// `TranscriptionProvider.notifyUtteranceBoundary()`, which system providers
/// (already producing their own volatile/final boundaries) simply ignore.
///
/// Must be fed **mic-only** samples, before any system-audio mixing —
/// feeding the mixed stream would defeat detection whenever background audio
/// is present. Ported from `mac-poc-hybrid`'s
/// `Audio/UtteranceSegmenter.swift`, plus live-tunable thresholds via
/// `update(silenceThresholdSeconds:silenceRMSDBFS:)`.
final class UtteranceSegmenter: @unchecked Sendable {
    var onUtteranceBoundary: (() -> Void)?

    private let sampleRate: Double = 16000
    static let defaultSilenceSeconds: Double = 0.6
    static let defaultSilenceDBFS: Double = -40

    // `submit` runs on the audio thread while the setters run on the main
    // actor, so the tunables sit behind a lock.
    private let lock = NSLock()
    private var silenceThresholdSeconds: Double
    private var silenceRMSDBFS: Float
    private var silentSampleCount: Int = 0
    private var hasSpeechSinceLastBoundary = false

    /// - Parameters:
    ///   - silenceThresholdSeconds: how long mic input must stay below the
    ///     silence threshold, after having seen speech, before this fires.
    ///   - silenceRMSDBFS: RMS level (dBFS) below which a chunk counts as
    ///     silence. Typical conversational speech sits well above -30dBFS;
    ///     room noise/silence is usually below -40dBFS.
    init(
        silenceThresholdSeconds: Double = UtteranceSegmenter.defaultSilenceSeconds,
        silenceRMSDBFS: Float = Float(UtteranceSegmenter.defaultSilenceDBFS)
    ) {
        self.silenceThresholdSeconds = silenceThresholdSeconds
        self.silenceRMSDBFS = silenceRMSDBFS
    }

    /// Live-updates the tunables; safe to call mid-recording.
    func update(silenceThresholdSeconds: Double, silenceRMSDBFS: Float) {
        lock.lock()
        defer { lock.unlock() }
        self.silenceThresholdSeconds = silenceThresholdSeconds
        self.silenceRMSDBFS = silenceRMSDBFS
    }

    /// Samples are mono Float32 in -1...1 range.
    func submit(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        let thresholdSeconds = silenceThresholdSeconds
        let thresholdDBFS = silenceRMSDBFS
        lock.unlock()
        let isSilent = Self.rmsDBFS(samples) < thresholdDBFS
        if isSilent {
            // Nothing left to close until the next speech, so don't keep counting.
            guard hasSpeechSinceLastBoundary else { return }
            silentSampleCount += samples.count
            let silenceSeconds = Double(silentSampleCount) / sampleRate
            if silenceSeconds >= thresholdSeconds {
                hasSpeechSinceLastBoundary = false
                silentSampleCount = 0
                onUtteranceBoundary?()
            }
        } else {
            silentSampleCount = 0
            hasSpeechSinceLastBoundary = true
        }
    }

    private static func rmsDBFS(_ samples: [Float]) -> Float {
        var sumSquares: Float = 0
        for sample in samples {
            sumSquares += sample * sample
        }
        let rms = (sumSquares / Float(samples.count)).squareRoot()
        guard rms > 0 else { return -.infinity }
        return 20 * log10(rms)
    }
}
