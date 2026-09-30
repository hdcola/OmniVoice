import CoreGraphics
import Foundation
import Testing
@testable import OmniVoiceCore

@Suite struct SelectionTextChunkerTests {
    @Test func keepsParagraphsAndBlankLinesAsVerbatimSeparators() {
        let pieces = SelectionTextChunker.pieces(of: "First line.\nSecond line.\n\n  Third paragraph.  ")
        #expect(pieces == [
            .text("First line."),
            .verbatim("\n"),
            .text("Second line."),
            .verbatim("\n\n"),
            .text("Third paragraph."),
        ])
    }

    @Test func keepsListMarkersOutOfTheTextSentForTranslation() {
        let pieces = SelectionTextChunker.pieces(of: "- item one\n2. item two\n3、第三项\n-5 degrees")
        #expect(pieces == [
            .verbatim("- "), .text("item one"),
            .verbatim("\n"),
            .verbatim("2. "), .text("item two"),
            .verbatim("\n"),
            .verbatim("3、"), .text("第三项"),
            .verbatim("\n"),
            .text("-5 degrees"),
        ])
    }

    @Test func rejoinsHardWrappedParagraphsAndListContinuations() {
        let text = """
        - **Selection translation**, modeled on Cida but fully on-device: select text
          in any app and press the shortcut, or frame part of the screen instead.
        - **Session history**: past recordings persisted locally, with
          a searchable history window.

        Short line.
        Another short line.
        """
        #expect(SelectionTextChunker.logicalLines(of: text) == [
            "- **Selection translation**, modeled on Cida but fully on-device: select text in any app and press the shortcut, or frame part of the screen instead.",
            "- **Session history**: past recordings persisted locally, with a searchable history window.",
            "",
            "Short line.",
            "Another short line.",
        ])
    }

    @Test func rejoinsWrappedChineseWithoutASpace() {
        let text = "这是一段很长的中文说明文字，它在固定宽度处被硬换行了，所以一句话被拆成了两行显示出来，\n需要重新拼接成一行再翻译。"
        #expect(SelectionTextChunker.logicalLines(of: text) == [
            "这是一段很长的中文说明文字，它在固定宽度处被硬换行了，所以一句话被拆成了两行显示出来，需要重新拼接成一行再翻译。",
        ])
    }

    @Test func dropsLeadingAndTrailingBlankLines() {
        #expect(SelectionTextChunker.pieces(of: "\n\nHello\n\n") == [.text("Hello")])
        #expect(SelectionTextChunker.pieces(of: " \n ").isEmpty)
    }

    @Test func splitsOverLongParagraphAtSentenceBoundaries() {
        let sentence = "This sentence is exactly forty chars. "
        let paragraph = String(repeating: sentence, count: 5).trimmingCharacters(in: .whitespaces)
        let pieces = SelectionTextChunker.pieces(of: paragraph, maxCharacters: 100)

        let texts = pieces.compactMap { piece -> String? in
            if case .text(let text) = piece { return text }
            return nil
        }
        #expect(texts.count > 1)
        #expect(texts.allSatisfy { $0.count <= 100 })
        #expect(texts.allSatisfy { $0.hasSuffix(".") })
        #expect(pieces.contains(.softBreak))
        #expect(!pieces.contains { if case .verbatim = $0 { return true } else { return false } })
    }

    @Test func hardSplitsASingleSentenceLongerThanTheLimit() {
        let pieces = SelectionTextChunker.pieces(of: String(repeating: "字", count: 250), maxCharacters: 100)
        #expect(pieces == [
            .text(String(repeating: "字", count: 100)), .softBreak,
            .text(String(repeating: "字", count: 100)), .softBreak,
            .text(String(repeating: "字", count: 50)),
        ])
    }
}

@Suite struct SelectionLanguageDirectionTests {
    @Test func detectsCommonLanguages() {
        let english = SelectionLanguageDirection.detectLanguageCode(of: "The quick brown fox jumps over the lazy dog.")
        #expect(english == "en")
        let chinese = SelectionLanguageDirection.detectLanguageCode(of: "今天天气很好，我们去公园散步吧。")
        #expect(chinese.map { SelectionLanguageDirection.isSameLanguage($0, "zh-CN") } == true)
    }

    @Test func kanaAndHangulOutweighAChineseHint() {
        let japanese = SelectionLanguageDirection.detectLanguageCode(
            of: "日本語のテキストも中国語に翻訳できますか？", myLanguageCode: "zh-CN", foreignLanguageCode: "en-US"
        )
        #expect(japanese == "ja")
        let korean = SelectionLanguageDirection.detectLanguageCode(
            of: "韓國語 텍스트도 번역됩니다", myLanguageCode: "zh-CN", foreignLanguageCode: "en-US"
        )
        #expect(korean == "ko")
    }

    @Test func myLanguageGoesToForeignAndEverythingElseComesHome() {
        func target(_ detected: String?) -> String {
            SelectionLanguageDirection.targetCode(forDetected: detected, myLanguageCode: "zh-CN", foreignLanguageCode: "en-US")
        }
        #expect(target("zh-Hans") == "en-US")
        #expect(target("zh-Hant") == "en-US")
        #expect(target("en") == "zh-CN")
        #expect(target("ja") == "zh-CN")
        #expect(target(nil) == "zh-CN")
    }

    @Test func treatsChineseVariantsAsOneLanguage() {
        #expect(SelectionLanguageDirection.isSameLanguage("zh-CN", "zh-TW"))
        #expect(SelectionLanguageDirection.isSameLanguage("yue-CN", "zh-Hans"))
        #expect(SelectionLanguageDirection.isSameLanguage("en-US", "en"))
        #expect(!SelectionLanguageDirection.isSameLanguage("ja-JP", "zh-CN"))
    }

    @Test func joinsWithoutSpacesOnlyForChineseAndJapanese() {
        #expect(SelectionLanguageDirection.joinsWithoutSpaces("zh-CN"))
        #expect(SelectionLanguageDirection.joinsWithoutSpaces("ja-JP"))
        #expect(SelectionLanguageDirection.joinsWithoutSpaces("yue-CN"))
        #expect(!SelectionLanguageDirection.joinsWithoutSpaces("en-US"))
        #expect(!SelectionLanguageDirection.joinsWithoutSpaces("ko-KR"))
    }
}

/// Records every call and answers with `"<target>:<text>"`.
@MainActor
private final class FakeModelBackend: SelectionModelTranslating {
    var requests: [String] = []
    var failure: Error?

    func isLoaded(modelURL: URL) -> Bool { true }

    func translate(
        _ text: String, targetLanguage: HYMT15TargetLanguage, sourceIsChinese: Bool, modelURL: URL
    ) async throws -> String {
        requests.append(text)
        if let failure { throw failure }
        return "\(targetLanguage.promptName):\(text)"
    }

    func unload() {}
}

@MainActor
@Suite struct SelectionTranslatorTests {
    private static func makeDefaults() -> UserDefaults {
        let suite = "SelectionTranslatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeTranslator(
        backend: FakeModelBackend = FakeModelBackend(),
        modelURL: URL? = URL(fileURLWithPath: "/tmp/hymt.gguf")
    ) -> SelectionTranslator {
        let translator = SelectionTranslator(defaults: Self.makeDefaults(), modelBackend: backend, modelURLProvider: { modelURL })
        translator.engineID = SelectionTranslationEngine.hymt15
        return translator
    }

    private func waitUntilSettled(_ translator: SelectionTranslator) async {
        for _ in 0..<200 where translator.isBusy {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func defaultsToFollowingTheRecordingAndChineseEnglishPair() {
        let translator = SelectionTranslator(defaults: Self.makeDefaults(), modelBackend: FakeModelBackend(), modelURLProvider: { nil })
        #expect(translator.engineID == SelectionTranslationEngine.followRecording)
        #expect(translator.myLanguageCode == "zh-CN")
        #expect(translator.foreignLanguageCode == "en-US")
    }

    @Test func followRecordingUsesTheRecordingEngineAndReplacesT3PO() {
        var recording: String? = SelectionTranslationEngine.system
        var modelURL: URL? = URL(fileURLWithPath: "/tmp/hymt.gguf")
        let translator = SelectionTranslator(
            defaults: Self.makeDefaults(), modelBackend: FakeModelBackend(),
            recordingEngineID: { recording }, modelURLProvider: { modelURL }
        )
        #expect(translator.effectiveEngineID == SelectionTranslationEngine.system)
        recording = SelectionTranslationEngine.hymt15
        #expect(translator.effectiveEngineID == SelectionTranslationEngine.hymt15)
        recording = "model.t3po"
        #expect(translator.effectiveEngineID == SelectionTranslationEngine.hymt15)
        modelURL = nil
        #expect(translator.effectiveEngineID == SelectionTranslationEngine.system)

        // An explicit choice ignores the recording.
        translator.engineID = SelectionTranslationEngine.system
        recording = SelectionTranslationEngine.hymt15
        #expect(translator.effectiveEngineID == SelectionTranslationEngine.system)
    }

    @Test func followRecordingRoutesTranslationsToTheResolvedEngine() async {
        let backend = FakeModelBackend()
        let translator = SelectionTranslator(
            defaults: Self.makeDefaults(), modelBackend: backend,
            recordingEngineID: { SelectionTranslationEngine.hymt15 },
            modelURLProvider: { URL(fileURLWithPath: "/tmp/hymt.gguf") }
        )
        translator.load("The quick brown fox jumps over the lazy dog.")
        await waitUntilSettled(translator)
        #expect(backend.requests == ["The quick brown fox jumps over the lazy dog."])
        #expect(translator.systemTranslationConfiguration == nil)
    }

    @Test func restoresPersistedSettingsAndIgnoresUnknownValues() {
        let defaults = Self.makeDefaults()
        defaults.set(SelectionTranslationEngine.hymt15, forKey: PersistedSelectionKey.engineID)
        defaults.set("ja-JP", forKey: PersistedSelectionKey.myLanguageCode)
        defaults.set("xx-XX", forKey: PersistedSelectionKey.foreignLanguageCode)
        let translator = SelectionTranslator(defaults: defaults, modelBackend: FakeModelBackend(), modelURLProvider: { nil })
        #expect(translator.engineID == SelectionTranslationEngine.hymt15)
        #expect(translator.myLanguageCode == "ja-JP")
        #expect(translator.foreignLanguageCode == "en-US")
    }

    @Test func translatesEachParagraphAndKeepsLayout() async {
        let backend = FakeModelBackend()
        let translator = makeTranslator(backend: backend)
        translator.load("Good morning, everyone.\n\nLet us begin the meeting now.")
        await waitUntilSettled(translator)

        #expect(backend.requests == ["Good morning, everyone.", "Let us begin the meeting now."])
        #expect(translator.targetCode == "zh-CN")
        #expect(translator.resultText == "Chinese:Good morning, everyone.\n\nChinese:Let us begin the meeting now.")
        #expect(translator.phase == .completed)
        #expect(!translator.isResultStale)
    }

    @Test func textInMyLanguageGoesToForeignLanguage() async {
        let translator = makeTranslator()
        translator.load("今天天气很好，我们去公园散步吧。")
        await waitUntilSettled(translator)
        #expect(translator.targetCode == "en-US")
        #expect(translator.resultText.hasPrefix("English:"))
    }

    @Test func overrideTargetWinsUntilNextSelection() async {
        let translator = makeTranslator()
        translator.load("The quick brown fox jumps over the lazy dog.")
        await waitUntilSettled(translator)
        translator.targetOverrideCode = "ja-JP"
        translator.translate()
        await waitUntilSettled(translator)
        #expect(translator.targetCode == "ja-JP")

        translator.load("A different sentence arrives from the next selection.")
        await waitUntilSettled(translator)
        #expect(translator.targetOverrideCode == nil)
        #expect(translator.targetCode == "zh-CN")
    }

    @Test func sameSelectionKeepsExistingResult() async {
        let backend = FakeModelBackend()
        let translator = makeTranslator(backend: backend)
        translator.load("Hello there, how are you today?")
        await waitUntilSettled(translator)
        translator.load("  Hello there, how are you today?\n")
        await waitUntilSettled(translator)
        #expect(backend.requests.count == 1)
    }

    @Test func editingSourceMarksResultStale() async {
        let translator = makeTranslator()
        translator.load("Hello there, how are you today?")
        await waitUntilSettled(translator)
        translator.sourceText = "Hello there, how are you tomorrow?"
        #expect(translator.isResultStale)
    }

    @Test func modelEngineRefusesTargetsItCannotProduce() async {
        let backend = FakeModelBackend()
        let translator = makeTranslator(backend: backend)
        translator.foreignLanguageCode = "fr-FR"
        translator.load("今天天气很好，我们去公园散步吧。")
        await waitUntilSettled(translator)
        #expect(backend.requests.isEmpty)
        guard case .failed(let message) = translator.phase else {
            Issue.record("expected failure, got \(translator.phase)")
            return
        }
        #expect(message.contains("法语"))
    }

    @Test func missingModelFailsWithDownloadHint() async {
        let translator = makeTranslator(modelURL: nil)
        translator.load("The quick brown fox jumps over the lazy dog.")
        await waitUntilSettled(translator)
        guard case .failed(let message) = translator.phase else {
            Issue.record("expected failure, got \(translator.phase)")
            return
        }
        #expect(message.contains("模型库管理"))
    }

    @Test func backendErrorSurfacesAsFailure() async {
        let backend = FakeModelBackend()
        backend.failure = TranslatorError.textTooLong
        let translator = makeTranslator(backend: backend)
        translator.load("The quick brown fox jumps over the lazy dog.")
        await waitUntilSettled(translator)
        #expect(translator.phase == .failed("翻译失败：\(TranslatorError.textTooLong.localizedDescription)"))
    }

    @Test func systemEnginePublishesConfigurationAndRunsThroughBridge() async {
        let translator = SelectionTranslator(defaults: Self.makeDefaults(), modelBackend: FakeModelBackend(), modelURLProvider: { nil })
        translator.engineID = SelectionTranslationEngine.system
        translator.load("The quick brown fox jumps over the lazy dog.")
        #expect(translator.systemTranslationConfiguration?.target == Locale.Language(identifier: "zh-CN"))
        #expect(translator.phase == .translating)

        await translator.runPendingSystemJob { "译:\($0)" }
        #expect(translator.resultText == "译:The quick brown fox jumps over the lazy dog.")
        #expect(translator.phase == .completed)
    }
}

@Suite struct RecognizedTextLayoutTests {
    private func line(_ text: String, x: CGFloat = 0.05, y: CGFloat, width: CGFloat = 0.9) -> RecognizedLine {
        RecognizedLine(text: text, frame: CGRect(x: x, y: y, width: width, height: 0.04))
    }

    @Test func joinsWrappedLatinRowsWithASpace() {
        let text = RecognizedTextLayout.text(from: [
            line("The quick brown fox jumps over the", y: 0.10),
            line("lazy dog.", y: 0.15, width: 0.25),
        ])
        #expect(text == "The quick brown fox jumps over the lazy dog.")
    }

    @Test func joinsWrappedChineseRowsWithoutASpace() {
        let text = RecognizedTextLayout.text(from: [
            line("今天天气很好，我们去公园", y: 0.10),
            line("散步吧。", y: 0.15, width: 0.3),
        ])
        #expect(text == "今天天气很好，我们去公园散步吧。")
    }

    @Test func breaksAtAParagraphGapAndListItems() {
        let text = RecognizedTextLayout.text(from: [
            line("First paragraph ends here", y: 0.10),
            line("Second paragraph starts after a gap", y: 0.25),
            line("- a list item", y: 0.30),
        ])
        #expect(text == "First paragraph ends here\nSecond paragraph starts after a gap\n- a list item")
    }

    @Test func readsSideBySideLinesLeftToRight() {
        let text = RecognizedTextLayout.text(from: [
            line("right", x: 0.6, y: 0.10, width: 0.3),
            line("left", x: 0.05, y: 0.10, width: 0.3),
        ])
        #expect(text == "left right")
    }

    @Test func returnsNilForNoText() {
        #expect(RecognizedTextLayout.text(from: []) == nil)
        #expect(RecognizedTextLayout.text(from: [line("  ", y: 0.1)]) == nil)
    }
}

/// Only the paths that need no real weights — sharing one loaded instance
/// is covered by a manual smoke run against a downloaded HY-MT1.5.
@MainActor
@Suite struct HYMT15ModelPoolTests {
    private let missing = URL(fileURLWithPath: "/nonexistent/omnivoice-test-hymt15.gguf")

    @Test func failedLoadIsNotCachedAndLeavesNothingLoaded() async {
        let pool = HYMT15ModelPool()
        for _ in 0..<2 {
            await #expect(throws: TranslatorError.self) { _ = try await pool.acquire(modelURL: missing) }
            #expect(!pool.isLoaded(modelURL: missing))
        }
    }

    @Test func concurrentFailedAcquisitionsAllFailAndTheNextOneRetries() async {
        let pool = HYMT15ModelPool()
        async let first: Void = { _ = try? await pool.acquire(modelURL: missing) }()
        async let second: Void = { _ = try? await pool.acquire(modelURL: missing) }()
        _ = await (first, second)
        #expect(!pool.isLoaded(modelURL: missing))
        await #expect(throws: TranslatorError.self) { _ = try await pool.acquire(modelURL: missing) }
    }

    /// A failed load must not be replayed: once the file appears (here, an
    /// invalid one), the next translation tries to load it for real — so
    /// the error changes from "missing" to "load failed".
    @Test func selectionBackendRetriesAfterAFailedLoad() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("omnivoice-test-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: url) }
        let backend = SelectionModelBackend(pool: HYMT15ModelPool())

        do {
            _ = try await backend.translate("hi", targetLanguage: .chinese, sourceIsChinese: false, modelURL: url)
            Issue.record("expected the missing file to fail")
        } catch TranslatorError.modelMissing {}

        try Data("not a gguf".utf8).write(to: url)
        do {
            _ = try await backend.translate("hi", targetLanguage: .chinese, sourceIsChinese: false, modelURL: url)
            Issue.record("expected the invalid file to fail")
        } catch TranslatorError.llamaCallFailed {}
    }

    @Test func releasingAnUnknownTranslatorIsANoOp() {
        HYMT15ModelPool().release(HYMT15Translator())
    }

    @Test func providerStillReportsFlushBoundaryWithoutALoadedModel() {
        let provider = HYMT15TranslationProvider(modelPath: missing)
        var boundaries = 0
        provider.onFlushBoundary = { boundaries += 1 }
        provider.flush()
        #expect(boundaries == 1)
        provider.unload()
    }
}
