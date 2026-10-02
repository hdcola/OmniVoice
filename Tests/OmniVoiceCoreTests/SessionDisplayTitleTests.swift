import Foundation
import Testing
@testable import OmniVoiceCore

struct SessionDisplayTitleTests {
    private func makeSession(title: String? = nil, texts: [String]) -> RecordingSessionRecord {
        let start = Date()
        let session = RecordingSessionRecord(
            title: title ?? RecordingSessionRecord.defaultTitle(for: start),
            startedAt: start,
            transcriptionEngineID: "t", translationEngineID: "x",
            sourceLanguageCode: nil, targetLanguageCode: "zh"
        )
        for (i, text) in texts.enumerated() {
            session.utterances.append(UtteranceRecord(index: i, sourceText: text, translationText: ""))
        }
        return session
    }

    @Test func defaultTitleFallsBackToFirstUtterance() {
        #expect(makeSession(texts: ["  Hello world \n", "second"]).displayTitle() == "Hello world")
    }

    @Test func longFirstUtteranceIsTruncated() {
        let title = makeSession(texts: [String(repeating: "a", count: 50)]).displayTitle(maxLength: 10)
        #expect(title == String(repeating: "a", count: 10) + "…")
    }

    @Test func leadingEmptyUtteranceIsSkipped() {
        #expect(makeSession(texts: ["", "  ", "Real words"]).displayTitle() == "Real words")
    }

    @Test func anyNewlineStyleCollapsesToOneSpace() {
        #expect(makeSession(texts: ["one\r\ntwo\n\nthree"]).displayTitle() == "one two three")
    }

    @Test func lowestIndexNonEmptyWinsRegardlessOfStorageOrder() {
        let session = makeSession(texts: ["", "b", "c"])
        session.utterances.reverse()
        #expect(session.displayTitle() == "b")
    }

    @Test func customTitleIsKept() {
        #expect(makeSession(title: "周会", texts: ["Hello"]).displayTitle() == "周会")
    }

    @Test func emptySessionKeepsDefaultTitle() {
        let session = makeSession(texts: [])
        #expect(session.displayTitle() == session.title)
    }
}
