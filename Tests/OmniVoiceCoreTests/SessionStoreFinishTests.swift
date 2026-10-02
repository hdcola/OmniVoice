import Testing
@testable import OmniVoiceCore

@MainActor
struct SessionStoreFinishTests {
    private func makeSession(in store: SessionStore) -> RecordingSessionRecord {
        store.createSession(
            title: "t", transcriptionEngineID: "t", translationEngineID: "x",
            sourceLanguageCode: nil, targetLanguageCode: "zh"
        )
    }

    @Test func emptySessionIsDroppedOnFinish() throws {
        let store = try SessionStore(inMemory: true)
        let session = makeSession(in: store)
        #expect(store.finish(session) == false)
        try store.save()
        #expect(try store.fetchAllSessions().isEmpty)
    }

    @Test func sessionWithUtterancesIsKeptAndEnded() throws {
        let store = try SessionStore(inMemory: true)
        let session = makeSession(in: store)
        store.appendUtterance(to: session, sourceText: "hi", translationText: "你好")
        #expect(store.finish(session) == true)
        try store.save()
        let all = try store.fetchAllSessions()
        #expect(all.count == 1)
        #expect(all[0].endedAt != nil)
    }
}
