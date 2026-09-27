import Foundation
import SwiftData

/// One recording — a meeting, lecture, or conversation the user captured.
/// Persisted via SwiftData so history survives relaunches and is searchable
/// without loading every session into memory.
@Model
public final class RecordingSessionRecord {
    @Attribute(.unique) public var id: UUID
    /// User-editable; defaults to a timestamp-derived title at creation.
    public var title: String
    public var startedAt: Date
    /// nil while the recording is still in progress (or was never cleanly
    /// stopped — e.g. the app crashed mid-recording).
    public var endedAt: Date?

    public var transcriptionEngineID: String
    public var translationEngineID: String
    public var sourceLanguageCode: String?
    public var targetLanguageCode: String

    @Relationship(deleteRule: .cascade, inverse: \UtteranceRecord.session)
    public var utterances: [UtteranceRecord] = []

    public init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date = .now,
        transcriptionEngineID: String,
        translationEngineID: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.transcriptionEngineID = transcriptionEngineID
        self.translationEngineID = translationEngineID
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
    }
}
