import Foundation

/// Shared "does this text look like it ends a sentence" check. Intended for
/// a `.model`-kind `TranscriptionProvider`'s own row-closing decision (e.g.
/// R2T2 needs this to decide when to emit `.segmentClosed`, since its LSP
/// output has no built-in segment boundary the way `SpeechTranscriber`'s
/// final/volatile distinction does) — see `mac-poc-hybrid`'s
/// `AppModel.ingestModelSourceText` for the original reasoning this was
/// factored out of. Kept here, not duplicated per-provider, so multiple
/// model engines can't drift apart on what counts as a sentence end.
public enum SentenceBoundary {
    public static let endingPunctuation: Set<Character> = [".", "!", "?", "。", "！", "？", "…", ";", "；"]

    /// Weaker, mid-clause break points — not "the sentence is over", just "a
    /// reasonable place to cut a row that's grown too long without ever
    /// hitting real sentence-ending punctuation". Chinese commas in
    /// particular show up far more often than periods in continuous
    /// unscripted/narrated speech.
    public static let softBreakPunctuation: Set<Character> = [",", "，", "、", "：", ":"]

    /// `.whitespacesAndNewlines`, not just `.whitespaces` — an ASR delta
    /// trailing in a newline (some engines' output does) would otherwise
    /// leave `.last` reading the newline itself, never the real
    /// sentence-ending punctuation before it, silently defeating this check.
    public static func endsSentence(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).last.map { endingPunctuation.contains($0) } ?? false
    }

    /// Same as `endsSentence`, but also accepts a soft break (e.g. a Chinese
    /// comma). Deliberately meant to be applied only to *newly arrived* text
    /// at the end of an already-appended/-fed run, never used to search
    /// backward into text already committed — see `mac-poc-hybrid`'s
    /// `AppModel.ingestModelSourceText` doc for why a backward search
    /// duplicates text across rows.
    public static func endsWithBreak(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).last.map {
            endingPunctuation.contains($0) || softBreakPunctuation.contains($0)
        } ?? false
    }
}
