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
/// is present. Ported unchanged from `mac-poc-hybrid`'s
/// `Audio/UtteranceSegmenter.swift`.
final class UtteranceSegmenter {
    var onUtteranceBoundary: (() -> Void)?

    private let sampleRate: Double = 16000
    private let silenceThresholdSeconds: Double
    private let silenceRMSDBFS: Float
    private var silentSampleCount: Int = 0
    private var hasSpeechSinceLastBoundary = false

    /// - Parameters:
    ///   - silenceThresholdSeconds: how long mic input must stay below the
    ///     silence threshold, after having seen speech, before this fires.
    ///   - silenceRMSDBFS: RMS level (dBFS) below which a chunk counts as
    ///     silence. Typical conversational speech sits well above -30dBFS;
    ///     room noise/silence is usually below -40dBFS.
    init(silenceThresholdSeconds: Double = 0.6, silenceRMSDBFS: Float = -40) {
        self.silenceThresholdSeconds = silenceThresholdSeconds
        self.silenceRMSDBFS = silenceRMSDBFS
    }

    /// Samples are mono Float32 in -1...1 range.
    func submit(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let isSilent = Self.rmsDBFS(samples) < silenceRMSDBFS
        if isSilent {
            silentSampleCount += samples.count
            let silenceSeconds = Double(silentSampleCount) / sampleRate
            if hasSpeechSinceLastBoundary && silenceSeconds >= silenceThresholdSeconds {
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
