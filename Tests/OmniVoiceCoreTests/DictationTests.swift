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
        #expect(assemble([.segmentClosed(finalAppend: "“Hello"), .segmentClosed(finalAppend: "”")]).text == "“Hello”")
    }

    @Test("padding the engine put at a seam doesn't leak into the joined text")
    func seamPaddingIgnored() {
        #expect(assemble([.segmentClosed(finalAppend: "Hello "), .segmentClosed(finalAppend: ", world")]).text == "Hello, world")
        #expect(assemble([.segmentClosed(finalAppend: "你好 "), .segmentClosed(finalAppend: "世界")]).text == "你好世界")
    }

    @Test("a right single quote attaches, so it + ’s stays one word")
    func apostropheAttaches() {
        #expect(assemble([.segmentClosed(finalAppend: "it"), .segmentClosed(finalAppend: "’s fine")]).text == "it’s fine")
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

    @Test("toggle: Return while listening finishes and sends")
    func toggleReturnSends() {
        var machine = DictationTriggerMachine(mode: .toggle)
        #expect(machine.keyDown(at: 0) == .start)
        #expect(machine.keyUp(at: 0.1) == .none)
        #expect(machine.isAwaitingReturn)
        #expect(machine.returnPressed() == .finishAndSend)
        #expect(!machine.isAwaitingReturn)
        // The trigger key afterwards starts a fresh dictation.
        #expect(machine.keyDown(at: 1) == .start)
    }

    @Test("Return does nothing in hold mode, with nothing listening, or while the trigger is held")
    func returnIgnoredOutsideToggleListening() {
        var hold = DictationTriggerMachine(mode: .hold)
        #expect(hold.keyDown(at: 0) == .start)
        #expect(hold.returnPressed() == .none)
        var toggle = DictationTriggerMachine(mode: .toggle)
        #expect(toggle.returnPressed() == .none)
        #expect(!toggle.isAwaitingReturn)
        #expect(toggle.keyDown(at: 0) == .start)
        #expect(toggle.returnPressed() == .none)
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

    @Test("hasLoadedLocalRecognizer is true only for a matching loaded model")
    func hasLoadedLocalRecognizer() {
        defer { cleanUp() }
        let session = makeSessionWithLoadedRecognizer()
        #expect(session.hasLoadedLocalRecognizer)
        session.loadedEngineIDs = (
            "model.r2t2", "some-old-variant-id",
            session.translationEngineID, session.currentTranslationModelVariant?.id
        )
        #expect(!session.hasLoadedLocalRecognizer)
        #expect(!RecordingSession().hasLoadedLocalRecognizer)
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

@Suite("SystemTranscriptionProvider.matchLocale")
struct LocaleMatchingTests {
    private let supported = ["en-US", "zh-TW", "zh-HK", "zh-CN", "ja-JP"].map { Locale(identifier: $0) }

    private func match(_ identifier: String) -> String? {
        SystemTranscriptionProvider.matchLocale(Locale(identifier: identifier), in: supported)?.identifier(.bcp47)
    }

    @Test("an exact tag matches itself")
    func exact() {
        #expect(match("zh-TW") == "zh-TW")
    }

    @Test("the system's script-qualified Chinese locale finds the plain region one")
    func scriptQualified() {
        #expect(match("zh-Hans-CN") == "zh-CN")
        #expect(match("zh-Hant-TW") == "zh-TW")
        #expect(match("zh_Hans_CN") == "zh-CN")
    }

    @Test("an unlisted region keeps the writing system rather than taking the first Chinese listed")
    func scriptKept() {
        #expect(match("zh-Hans-SG") == "zh-CN")
        #expect(match("zh-Hans-US") == "zh-CN")
        #expect(match("zh-Hant-US") == "zh-TW")
        #expect(match("zh") == "zh-CN")
    }

    @Test("an unlisted region falls back to the same language")
    func languageOnly() {
        #expect(match("en-AU") == "en-US")
    }

    @Test("an unsupported language matches nothing")
    func unsupported() {
        #expect(match("fr-FR") == nil)
    }
}

@Suite("DictationKeyTracker")
struct DictationKeyTrackerTests {
    private typealias Event = DictationKeyTracker.Event

    private func trigger(_ tracker: inout DictationKeyTracker, held: Bool, only: Bool = true) -> Event? {
        tracker.flagsChanged(isTriggerKey: true, triggerFlagHeld: held, onlyTriggerModifierHeld: only)
    }

    private func other(_ tracker: inout DictationKeyTracker, flagHeld: Bool) -> Event? {
        tracker.flagsChanged(isTriggerKey: false, triggerFlagHeld: flagHeld, onlyTriggerModifierHeld: false)
    }

    @Test("a plain press and release")
    func pressRelease() {
        var tracker = DictationKeyTracker()
        #expect(trigger(&tracker, held: true) == .down)
        #expect(trigger(&tracker, held: false) == .up)
    }

    @Test("releasing the trigger while the other copy of the modifier is held still releases it")
    func leftAndRightCopies() {
        var tracker = DictationKeyTracker()
        #expect(trigger(&tracker, held: true) == .down)
        // The left copy joins: the flag stays set, the dictation is a chord.
        #expect(other(&tracker, flagHeld: true) == .otherKey)
        // The right copy comes up but the flag is still set by the left one.
        #expect(trigger(&tracker, held: true) == .up)
        #expect(other(&tracker, flagHeld: false) == nil)
        // Not stuck: the next press works.
        #expect(trigger(&tracker, held: true) == .down)
    }

    @Test("a trigger pressed with another modifier already held is a chord")
    func chord() {
        var tracker = DictationKeyTracker()
        #expect(trigger(&tracker, held: true, only: false) == nil)
        #expect(trigger(&tracker, held: false, only: false) == nil)
        #expect(trigger(&tracker, held: true) == .down)
    }

    @Test("a release that was never seen is noticed when the modifier is up")
    func missedRelease() {
        var tracker = DictationKeyTracker()
        _ = trigger(&tracker, held: true)
        #expect(other(&tracker, flagHeld: false) == .up)
        #expect(trigger(&tracker, held: true) == .down)
    }

    @Test("another key while held is a chord; Esc is always Esc; idle keys are ignored")
    func keys() {
        var tracker = DictationKeyTracker()
        #expect(tracker.keyDown(isEscape: false) == nil)
        #expect(tracker.keyDown(isEscape: true) == .escape)
        _ = trigger(&tracker, held: true)
        #expect(tracker.keyDown(isEscape: false) == .otherKey)
    }
}
