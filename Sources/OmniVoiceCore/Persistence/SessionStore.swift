import Foundation
import SwiftData

/// Thin wrapper around a SwiftData `ModelContainer`/`ModelContext` for
/// `RecordingSessionRecord`/`UtteranceRecord` CRUD — kept as one small,
/// testable surface instead of scattering `ModelContext` calls through the
/// app's views and `RecordingSession`.
@MainActor
public final class SessionStore {
    public let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    /// - Parameter inMemory: `true` for previews/tests; `false` (the
    ///   default) persists to the app's Application Support directory.
    public init(inMemory: Bool = false) throws {
        let schema = Schema([RecordingSessionRecord.self, UtteranceRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: schema, configurations: [configuration])
    }

    public func createSession(
        title: String,
        transcriptionEngineID: String,
        translationEngineID: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) -> RecordingSessionRecord {
        let session = RecordingSessionRecord(
            title: title,
            transcriptionEngineID: transcriptionEngineID,
            translationEngineID: translationEngineID,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )
        context.insert(session)
        return session
    }

    public func appendUtterance(to session: RecordingSessionRecord, sourceText: String, translationText: String) {
        let utterance = UtteranceRecord(
            index: session.utterances.count,
            sourceText: sourceText,
            translationText: translationText
        )
        utterance.session = session
        session.utterances.append(utterance)
    }

    public func endSession(_ session: RecordingSessionRecord, at date: Date = .now) {
        session.endedAt = date
    }

    public func delete(_ session: RecordingSessionRecord) {
        context.delete(session)
    }

    public func save() throws {
        try context.save()
    }

    /// All sessions, newest first.
    public func fetchAllSessions() throws -> [RecordingSessionRecord] {
        let descriptor = FetchDescriptor<RecordingSessionRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// Sessions with at least one utterance whose source or translation text
    /// contains `query` (case-insensitive), newest first. A simple
    /// substring/predicate search — swappable for SwiftData's `#Index`-backed
    /// full-text search later without changing this method's signature.
    public func searchSessions(matching query: String) throws -> [RecordingSessionRecord] {
        guard !query.isEmpty else { return try fetchAllSessions() }
        let all = try fetchAllSessions()
        return all.filter { session in
            session.title.localizedCaseInsensitiveContains(query)
                || session.utterances.contains {
                    $0.sourceText.localizedCaseInsensitiveContains(query)
                        || $0.translationText.localizedCaseInsensitiveContains(query)
                }
        }
    }
}
