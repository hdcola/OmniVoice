import Testing
@testable import OmniVoiceCore

/// Covers `TranscriptLine`'s `Equatable` conformance — added so
/// `FloatingTranscriptView`'s `.onChange(of: session.lines)` (driving
/// auto-scroll) can actually detect per-character ASR/translation deltas,
/// not just whole-row additions/removals.
struct TranscriptLineTests {
    @Test func linesWithIdenticalFieldsAreEqual() {
        var a = TranscriptLine(id: 0)
        a.source = "hello"
        var b = TranscriptLine(id: 0)
        b.source = "hello"
        #expect(a == b)
    }

    @Test func linesDifferingOnlyInTentativeTextAreNotEqual() {
        var a = TranscriptLine(id: 0)
        a.source = "hello"
        a.sourceTentative = ""
        var b = TranscriptLine(id: 0)
        b.source = "hello"
        b.sourceTentative = " world"
        #expect(a != b)
    }
}
