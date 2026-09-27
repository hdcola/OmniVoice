import Foundation
import SwiftData

/// One aligned source/translation row within a `RecordingSessionRecord` —
/// the persisted equivalent of a closed `TranscriptLine` (see
/// `RecordingSession`). Only committed, final text is ever written here;
/// in-progress/preview text never gets this far.
@Model
public final class UtteranceRecord {
    /// Position within the session — rows are appended in order, so this is
    /// also the sort key for display.
    public var index: Int
    public var sourceText: String
    public var translationText: String
    public var createdAt: Date

    public var session: RecordingSessionRecord?

    public init(
        index: Int,
        sourceText: String,
        translationText: String,
        createdAt: Date = .now
    ) {
        self.index = index
        self.sourceText = sourceText
        self.translationText = translationText
        self.createdAt = createdAt
    }
}
