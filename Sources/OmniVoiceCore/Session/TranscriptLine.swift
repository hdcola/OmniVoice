import Foundation

/// One row of the aligned source/translation transcript, in-memory —
/// `RecordingSession.lines`' element type. Only closed rows (once
/// `TranscriptionEvent.segmentClosed` has been handled) are ever persisted
/// as an `UtteranceRecord`; `sourceTentative`/`translationPreview` are
/// display-only and never written to disk.
public struct TranscriptLine: Identifiable, Sendable {
    public let id: Int
    /// Committed source text — append-only, never revised.
    public var source: String = ""
    /// The currently-open segment's tentative/volatile text, if the active
    /// ASR engine reports one (see `TranscriptionEvent.revised`) — render as
    /// `source + sourceTentative`, visually distinguished from `source`.
    public var sourceTentative: String = ""
    /// Committed translation text — append-only, never revised.
    public var translation: String = ""
    /// A translation engine's live best-guess for whatever's currently
    /// un-committed, if it reports one (see `TranslationProvider.onPreview`) —
    /// render as `translation + translationPreview`, visually distinguished.
    public var translationPreview: String = ""

    public init(id: Int) {
        self.id = id
    }

    public var displaySource: String { source + sourceTentative }
    public var displayTranslation: String { translation + translationPreview }
}
