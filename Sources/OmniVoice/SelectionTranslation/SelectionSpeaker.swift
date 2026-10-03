import AVFoundation
import OmniVoiceCore

/// Reads the translation panel's source or result aloud with the macOS
/// system voices (`AVSpeechSynthesizer`) — no permission, no model.
/// One thing speaks at a time: starting the other pane, or stopping,
/// cuts the current one off.
@MainActor
final class SelectionSpeaker: NSObject, ObservableObject {
    enum Target { case source, result }

    /// Which pane is being read right now — drives the buttons' icons.
    @Published private(set) var speaking: Target?

    /// Whether a finished translation is read aloud by itself.
    @Published var autoSpeakResult: Bool {
        didSet { UserDefaults.standard.set(autoSpeakResult, forKey: Self.autoSpeakKey) }
    }

    /// `AVSpeechUtterance.rate`, kept inside the range that stays natural.
    @Published var rate: Float {
        didSet { UserDefaults.standard.set(rate, forKey: Self.rateKey) }
    }

    static let autoSpeakKey = "selectionSpeechAutoSpeak"
    static let rateKey = "selectionSpeechRate"
    static let rateRange: ClosedRange<Float> = 0.3...0.6
    /// The system's normal speaking rate — the "1×" of the settings label.
    static let defaultRate = AVSpeechUtteranceDefaultSpeechRate

    private let synthesizer = AVSpeechSynthesizer()
    /// The last utterance queued for the current reading; its finish/cancel
    /// callback is what ends `speaking`. Identifiers rather than the
    /// utterance itself so a stale callback from a cut-off reading can be
    /// told apart from the current one.
    private var lastUtteranceID: ObjectIdentifier?

    override init() {
        let defaults = UserDefaults.standard
        autoSpeakResult = defaults.bool(forKey: Self.autoSpeakKey)
        let stored = defaults.object(forKey: Self.rateKey) as? Float
        rate = stored.map { min(max($0, Self.rateRange.lowerBound), Self.rateRange.upperBound) }
            ?? Self.defaultRate
        super.init()
        synthesizer.delegate = self
    }

    /// The installed voices, as `SpeechVoiceResolver` wants them.
    static func installedVoices() -> [SpeechVoiceCandidate] {
        AVSpeechSynthesisVoice.speechVoices().map {
            SpeechVoiceCandidate(identifier: $0.identifier, language: $0.language, quality: $0.quality.rawValue)
        }
    }

    /// Starts reading `text` for `target` with the best voice for
    /// `languageCode`, or stops if `target` is already being read. Returns
    /// false (and says nothing) when no installed voice speaks the language.
    @discardableResult
    func toggle(_ target: Target, text: String, languageCode: String) -> Bool {
        if speaking == target {
            stop()
            return true
        }
        return speak(target, text: text, languageCode: languageCode)
    }

    /// Starts reading `text`, replacing whatever was being read. Returns
    /// false when no installed voice speaks `languageCode`.
    @discardableResult
    func speak(_ target: Target, text: String, languageCode: String) -> Bool {
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let candidate = SpeechVoiceResolver.bestVoice(for: languageCode, among: Self.installedVoices()),
              let voice = AVSpeechSynthesisVoice(identifier: candidate.identifier)
        else { return false }

        // One utterance per paragraph: the pause between them reads like
        // the text's own breaks.
        let paragraphs = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let utterances = paragraphs.map { paragraph -> AVSpeechUtterance in
            let utterance = AVSpeechUtterance(string: paragraph)
            utterance.voice = voice
            utterance.rate = rate
            return utterance
        }
        guard let last = utterances.last else { return false }
        lastUtteranceID = ObjectIdentifier(last)
        speaking = target
        utterances.forEach { synthesizer.speak($0) }
        return true
    }

    func stop() {
        lastUtteranceID = nil
        speaking = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func utteranceEnded(_ id: ObjectIdentifier) {
        guard id == lastUtteranceID else { return }
        lastUtteranceID = nil
        speaking = nil
    }
}

extension SelectionSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }
}
