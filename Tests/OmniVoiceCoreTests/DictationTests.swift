import Foundation
import Testing
@testable import OmniVoiceCore

@Suite("DictationTextAssembler")
struct DictationTextAssemblerTests {
    private func assemble(_ events: [TranscriptionEvent]) -> DictationTextAssembler {
        var assembler = DictationTextAssembler()
        events.forEach { assembler.apply($0) }
        return assembler
    }

    @Test("a replace-style engine's final text is the segment, not an addition to its hypothesis")
    func revisedThenClosed() {
        let assembler = assemble([.revised("hello wor"), .revised("hello world"), .segmentClosed(finalAppend: "Hello world.")])
        #expect(assembler.text == "Hello world.")
        #expect(assembler.pending.isEmpty)
    }

    @Test("an append-style engine's close adds only the tail")
    func appendedThenClosed() {
        let assembler = assemble([.appended("hello "), .appended("wor"), .segmentClosed(finalAppend: "ld")])
        #expect(assembler.text == "hello world")
    }

    @Test("the open segment counts, so text survives a stop before it closes")
    func openSegmentIncluded() {
        let assembler = assemble([.segmentClosed(finalAppend: "First."), .revised("second part")])
        #expect(assembler.text == "First. second part")
    }

    @Test("segments of space-delimited text are joined with one space")
    func latinJoin() {
        let assembler = assemble([.segmentClosed(finalAppend: "one"), .segmentClosed(finalAppend: " two ")])
        #expect(assembler.text == "one two")
    }

    @Test("CJK segments are joined without a space")
    func cjkJoin() {
        let assembler = assemble([.segmentClosed(finalAppend: "你好，"), .segmentClosed(finalAppend: "世界")])
        #expect(assembler.text == "你好，世界")
    }

    @Test("mixed CJK and Latin text gets no space at the boundary")
    func mixedJoin() {
        let assembler = assemble([.segmentClosed(finalAppend: "打开"), .segmentClosed(finalAppend: "Safari")])
        #expect(assembler.text == "打开Safari")
    }

    @Test("a segment that starts with closing punctuation attaches to the word before it")
    func punctuationAttaches() {
        #expect(assemble([.segmentClosed(finalAppend: "Hello"), .segmentClosed(finalAppend: ", world")]).text == "Hello, world")
        #expect(assemble([.segmentClosed(finalAppend: "Hello"), .segmentClosed(finalAppend: ".")]).text == "Hello.")
    }

    @Test("an opening bracket still gets its space")
    func openingBracketKeepsSpace() {
        #expect(assemble([.segmentClosed(finalAppend: "see"), .segmentClosed(finalAppend: "(note)")]).text == "see (note)")
    }

    @Test("Korean segments keep the space between words")
    func koreanJoin() {
        let assembler = assemble([.segmentClosed(finalAppend: "안녕하세요"), .segmentClosed(finalAppend: "반갑습니다")])
        #expect(assembler.text == "안녕하세요 반갑습니다")
    }

    @Test("nothing heard is empty")
    func empty() {
        #expect(DictationTextAssembler().text.isEmpty)
        #expect(assemble([.revised("  ")]).text.isEmpty)
    }
}

@Suite("DictationTriggerMachine")
struct DictationTriggerMachineTests {
    @Test("hold: press starts, a long hold finishes on release")
    func holdFinishes() {
        var machine = DictationTriggerMachine(mode: .hold)
        #expect(machine.keyDown(at: 10) == .start)
        #expect(machine.keyUp(at: 12) == .finish)
    }

    @Test("hold: a tap shorter than the minimum is cancelled")
    func holdTapCancelled() {
        var machine = DictationTriggerMachine(mode: .hold, minimumHold: 0.3)
        #expect(machine.keyDown(at: 10) == .start)
        #expect(machine.keyUp(at: 10.1) == .cancel)
    }

    @Test("hold: typing another key while held cancels, and release then does nothing")
    func holdChord() {
        var machine = DictationTriggerMachine(mode: .hold)
        #expect(machine.keyDown(at: 10) == .start)
        #expect(machine.otherKeyPressed() == .cancel)
        #expect(machine.keyUp(at: 11) == .none)
    }

    @Test("hold: a key typed with nothing held is ignored")
    func otherKeyIdle() {
        var machine = DictationTriggerMachine(mode: .hold)
        #expect(machine.otherKeyPressed() == .none)
    }

    @Test("toggle: one tap starts, the next finishes")
    func toggle() {
        var machine = DictationTriggerMachine(mode: .toggle)
        #expect(machine.keyDown(at: 10) == .start)
        #expect(machine.keyUp(at: 10.1) == .none)
        #expect(machine.keyDown(at: 15) == .finish)
        #expect(machine.keyUp(at: 15.1) == .none)
        #expect(machine.keyDown(at: 20) == .start)
    }

    @Test("toggle: typing while the key is up does not cancel")
    func toggleTypingWhileListening() {
        var machine = DictationTriggerMachine(mode: .toggle)
        _ = machine.keyDown(at: 10)
        _ = machine.keyUp(at: 10.1)
        #expect(machine.otherKeyPressed() == .none)
        #expect(machine.keyDown(at: 12) == .finish)
    }

    @Test("a repeated key-down without a release is ignored")
    func repeatedDown() {
        var machine = DictationTriggerMachine(mode: .hold)
        #expect(machine.keyDown(at: 10) == .start)
        #expect(machine.keyDown(at: 10.5) == .none)
    }

    @Test("Esc cancels a toggle-mode dictation that the released trigger can't")
    func escapeInToggle() {
        var machine = DictationTriggerMachine(mode: .toggle)
        _ = machine.keyDown(at: 10)
        _ = machine.keyUp(at: 10.1)
        #expect(machine.escapePressed() == .cancel)
        #expect(machine.keyDown(at: 20) == .start)
    }

    @Test("Esc with nothing listening does nothing")
    func escapeIdle() {
        var machine = DictationTriggerMachine(mode: .hold)
        #expect(machine.escapePressed() == .none)
    }

    @Test("reset while the key is still down doesn't swallow the next press")
    func resetWhileHeld() {
        var machine = DictationTriggerMachine(mode: .hold)
        _ = machine.keyDown(at: 10)
        machine.reset()
        #expect(machine.keyDown(at: 20) == .start)
    }

    @Test("reset lets the next press start again")
    func reset() {
        var machine = DictationTriggerMachine(mode: .toggle)
        _ = machine.keyDown(at: 10)
        _ = machine.keyUp(at: 10.1)
        machine.reset()
        #expect(machine.keyDown(at: 20) == .start)
    }
}

@MainActor
@Suite(.serialized)
struct DictationRecognizerLendingTests {
    private let defaults = UserDefaults.standard

    @Test("a system engine has nothing to lend")
    func systemEngineLendsNothing() {
        let session = RecordingSession()
        session.transcriptionEngineID = "system.speech"
        #expect(session.lendRecognizerToDictation() == nil)
    }

    @Test("a model engine that isn't loaded yet lends nothing")
    func unloadedModelLendsNothing() {
        defer {
            defaults.removeObject(forKey: PersistedSettingsKey.transcriptionEngineID)
            defaults.removeObject(forKey: PersistedSettingsKey.transcriptionModelVariantID)
        }
        let session = RecordingSession()
        session.transcriptionEngineID = "model.r2t2"
        #expect(session.lendRecognizerToDictation() == nil)
    }

    @Test("a load recorded for another variant is not lent")
    func staleLoadLendsNothing() {
        defer {
            defaults.removeObject(forKey: PersistedSettingsKey.transcriptionEngineID)
            defaults.removeObject(forKey: PersistedSettingsKey.transcriptionModelVariantID)
        }
        let session = RecordingSession()
        session.transcriptionEngineID = "model.r2t2"
        session.isModelLoaded = true
        session.loadedEngineIDs = (
            "model.r2t2", "some-old-variant-id",
            session.translationEngineID, session.currentTranslationModelVariant?.id
        )
        #expect(session.lendRecognizerToDictation() == nil)
    }
}

@Suite("DictationTranscript")
struct DictationTranscriptTests {
    @Test("the text is complete as soon as the last event has been applied, from any thread")
    func lastEventCounts() async {
        let transcript = DictationTranscript()
        await Task.detached {
            _ = transcript.apply(.revised("hello"))
            _ = transcript.apply(.segmentClosed(finalAppend: "hello"))
            _ = transcript.apply(.segmentClosed(finalAppend: "world"))
        }.value
        #expect(transcript.text == "hello world")
    }
}

@MainActor
@Suite(.serialized)
struct DictationRecognizerLeaseTests {
    private let defaults = UserDefaults.standard

    /// A session whose selected R2T2 engine has a stand-in recognizer "loaded".
    private func makeSessionWithLoadedRecognizer() -> RecordingSession {
        let session = RecordingSession()
        session.transcriptionEngineID = "model.r2t2"
        session.transcriptionProvider = ModelTranscriptionProvider()
        session.isModelLoaded = true
        session.loadedEngineIDs = (
            "model.r2t2", session.currentTranscriptionModelVariant?.id,
            session.translationEngineID, session.currentTranslationModelVariant?.id
        )
        return session
    }

    private func cleanUp() {
        defaults.removeObject(forKey: PersistedSettingsKey.transcriptionEngineID)
        defaults.removeObject(forKey: PersistedSettingsKey.transcriptionModelVariantID)
    }

    @Test("a loaded recognizer is lent once and available again once returned")
    func lendAndReturn() {
        defer { cleanUp() }
        let session = makeSessionWithLoadedRecognizer()
        #expect(session.lendRecognizerToDictation() != nil)
        #expect(session.lendRecognizerToDictation() == nil)
        session.returnRecognizerFromDictation()
        #expect(session.lendRecognizerToDictation() != nil)
    }

    @Test("while lent, unloading and starting a recording leave the model alone")
    func lentModelIsProtected() async {
        defer { cleanUp() }
        let session = makeSessionWithLoadedRecognizer()
        _ = session.lendRecognizerToDictation()

        session.unloadModels()
        #expect(session.isModelLoaded)

        await session.start()
        #expect(!session.isRunning)
        #expect(!session.isStarting)
        #expect(session.statusMessage == "正在语音输入，请稍后再开始")
    }

    @Test("an engine switch made while lent discards the stale load once it is returned")
    func staleLoadDiscardedOnReturn() {
        defer { cleanUp() }
        let session = makeSessionWithLoadedRecognizer()
        _ = session.lendRecognizerToDictation()

        session.transcriptionEngineID = "system.speech"
        #expect(session.isModelLoaded)

        session.returnRecognizerFromDictation()
        #expect(!session.isModelLoaded)
    }
}
