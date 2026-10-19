import Foundation

/// The microphone level behind the green meter — the live transcription's
/// (`RecordingSession.inputLevel`) and the Dictation bubble's
/// (`DictationSession.inputLevel`).
public enum InputLevel {
    /// Peak amplitude as a 0...1 level on a dBFS scale rather than a linear
    /// one — normal speech barely moves a linear peak meter.
    public static func peak(_ samples: [Float]) -> Float {
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

    /// Fast attack / slow decay, so the meter reacts instantly to louder
    /// sound but doesn't flicker down to zero between syllables.
    public static func smoothed(current: Float, new level: Float) -> Float {
        level > current ? level : current * 0.7 + level * 0.3
    }
}
