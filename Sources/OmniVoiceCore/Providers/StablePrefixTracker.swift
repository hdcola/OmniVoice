import Foundation

/// Turns a full-replace ASR hypothesis stream (sherpa re-reports the whole
/// current utterance on every decode) into append-only deltas, so a
/// `TranslationProvider` can start working before the segment closes.
///
/// A prefix counts as stable once two consecutive hypotheses agree on it and
/// it is at least `holdback` characters away from the end of the newer one —
/// the tail is where a streaming recognizer still rewrites its guess. Once a
/// prefix has been emitted it is never retracted; if a later hypothesis
/// rewrites inside it, the tracker simply stops emitting for that segment
/// and the segment's final text is reconciled by `close(finalText:)`.
struct StablePrefixTracker {
    let holdback: Int
    private var emitted = ""
    private var previous = ""

    init(holdback: Int = 6) {
        self.holdback = holdback
    }

    /// Feeds one hypothesis. Returns the newly stable text to append (nil
    /// when nothing new) and the remaining tentative text to display.
    mutating func ingest(_ hypothesis: String) -> (appended: String?, tentative: String) {
        defer { previous = hypothesis }
        guard hypothesis.hasPrefix(emitted) else {
            // The recognizer rewrote text we already committed; leave it be
            // and keep showing what follows the part both still agree on.
            return (nil, reconciledTail(of: hypothesis))
        }
        let common = hypothesis.commonPrefix(with: previous)
        let stableCount = max(0, min(common.count, hypothesis.count - holdback))
        let stable = String(hypothesis.prefix(stableCount))
        var appended: String?
        if stable.count > emitted.count, stable.hasPrefix(emitted) {
            appended = String(stable.dropFirst(emitted.count))
            emitted = stable
        }
        return (appended, String(hypothesis.dropFirst(emitted.count)))
    }

    /// Ends the segment: returns the part of `finalText` not yet emitted and
    /// resets for the next segment.
    mutating func close(finalText: String) -> String {
        defer { emitted = ""; previous = "" }
        guard finalText.hasPrefix(emitted) else {
            // Final text diverged from what was committed; the committed
            // prefix can't be retracted, so only deliver what lies beyond it.
            return reconciledTail(of: finalText)
        }
        return String(finalText.dropFirst(emitted.count))
    }

    /// The part of `text` to deliver after `emitted` when `text` no longer
    /// starts with it: everything past the common prefix, except that a
    /// divergence inside a word backs up to the word's start (the wrong word
    /// stays, but nothing is spliced or lost). A space keeps a word from
    /// gluing onto emitted text that ends in a word of a spaced script.
    private func reconciledTail(of text: String) -> String {
        let emittedChars = Array(emitted)
        let textChars = Array(text)
        var common = 0
        while common < emittedChars.count, common < textChars.count,
            emittedChars[common] == textChars[common]
        {
            common += 1
        }
        // Everything in `text` is already emitted; appending would duplicate it.
        if common == textChars.count { return "" }
        func isWordCharacter(_ character: Character) -> Bool {
            (character.isLetter || character.isNumber)
                && !DictationTextAssembler.isSpaceless(character)
        }
        if common > 0, isWordCharacter(textChars[common - 1]),
            isWordCharacter(textChars[common])
                || (common < emittedChars.count && isWordCharacter(emittedChars[common]))
        {
            let lastSpace = textChars[..<common].lastIndex { $0.isWhitespace }
            common = lastSpace.map { $0 + 1 } ?? 0
        }
        let tail = String(textChars[common...])
        if let first = tail.first, let last = emittedChars.last,
            isWordCharacter(first), isWordCharacter(last)
        {
            return " " + tail
        }
        return tail
    }

    mutating func reset() {
        emitted = ""
        previous = ""
    }
}
