import Testing
@testable import OmniVoiceCore

/// Covers `TranslationConfig.earlyTranslateThreshold`'s length-threshold
/// behavior for a one-shot engine — see `SystemTranslationProvider.feed(_:)`'s
/// doc for why a long, pause-free utterance needs an early, non-final bridge
/// request rather than waiting for `flush()`.
@MainActor
struct SystemTranslationProviderTests {
    @Test func feedBelowThresholdSendsNoBridgeRequest() async throws {
        let provider = SystemTranslationProvider()
        var requests: [TranslationBridgeRequest] = []
        provider.onBridgeRequest = { requests.append($0) }
        try await provider.start(config: TranslationConfig(targetLanguageCode: "zh-CN", earlyTranslateThreshold: 60))

        provider.feed("short")

        #expect(requests.isEmpty)
    }

    @Test func feedCrossingThresholdSendsANonFinalBridgeRequestAndClearsTheBuffer() async throws {
        let provider = SystemTranslationProvider()
        var requests: [TranslationBridgeRequest] = []
        provider.onBridgeRequest = { requests.append($0) }
        try await provider.start(config: TranslationConfig(targetLanguageCode: "zh-CN", earlyTranslateThreshold: 60))

        let longText = String(repeating: "x", count: 60)
        provider.feed(longText)

        #expect(requests.count == 1)
        #expect(requests.first?.text == longText)
        #expect(requests.first?.isFinal == false)

        // The buffer was cleared by the early request — a subsequent flush
        // with nothing new fed should have nothing left to send.
        provider.flush()
        #expect(requests.count == 1)
    }

    @Test func flushSendsAFinalBridgeRequest() async throws {
        let provider = SystemTranslationProvider()
        var requests: [TranslationBridgeRequest] = []
        provider.onBridgeRequest = { requests.append($0) }
        try await provider.start(config: TranslationConfig(targetLanguageCode: "zh-CN"))

        provider.feed("hello")
        provider.flush()

        #expect(requests.count == 1)
        #expect(requests.first?.isFinal == true)
    }

    @Test func receiveResultOnlyFiresFlushBoundaryWhenFinal() {
        let provider = SystemTranslationProvider()
        var commits: [String] = []
        var flushBoundaryCount = 0
        provider.onCommit = { commits.append($0) }
        provider.onFlushBoundary = { flushBoundaryCount += 1 }

        provider.receiveResult("早期片段", isFinal: false)
        #expect(commits == ["早期片段"])
        #expect(flushBoundaryCount == 0)

        provider.receiveResult("最终片段", isFinal: true)
        #expect(commits == ["早期片段", "最终片段"])
        #expect(flushBoundaryCount == 1)
    }

    @Test func crossingTheSoftBreakThresholdWithoutSentenceEndingPunctuationDoesNotSendARequest() async throws {
        let provider = SystemTranslationProvider()
        var requests: [TranslationBridgeRequest] = []
        provider.onBridgeRequest = { requests.append($0) }
        try await provider.start(config: TranslationConfig(targetLanguageCode: "zh-CN", earlyTranslateThreshold: 60))

        // Past half the threshold, but nowhere near the full one, and this
        // delta doesn't end a sentence — should keep buffering.
        provider.feed(String(repeating: "x", count: 31))

        #expect(requests.isEmpty)
    }

    @Test func crossingTheSoftBreakThresholdWithSentenceEndingPunctuationSendsAnEarlyRequest() async throws {
        let provider = SystemTranslationProvider()
        var requests: [TranslationBridgeRequest] = []
        provider.onBridgeRequest = { requests.append($0) }
        try await provider.start(config: TranslationConfig(targetLanguageCode: "zh-CN", earlyTranslateThreshold: 60))

        provider.feed(String(repeating: "x", count: 30))
        #expect(requests.isEmpty)

        // This delta crosses half the threshold *and* ends a sentence —
        // should translate early, well below the full threshold.
        provider.feed("。")

        #expect(requests.count == 1)
        #expect(requests.first?.isFinal == false)
    }

    @Test func flushWithAnEmptyBufferAndNothingPendingFiresTheBoundaryImmediately() async throws {
        let provider = SystemTranslationProvider()
        var flushBoundaryCount = 0
        provider.onBridgeRequest = { _ in }
        provider.onFlushBoundary = { flushBoundaryCount += 1 }
        try await provider.start(config: TranslationConfig(targetLanguageCode: "zh-CN"))

        provider.flush()

        #expect(flushBoundaryCount == 1)
    }

    /// Regression test for a real race: an early (non-final) request drains
    /// the buffer, then a `flush()` (an ASR segment boundary arriving before
    /// that request's async result comes back) must *not* fire
    /// `onFlushBoundary` right away — doing so would advance
    /// `translationRowIndex` before the pending request's `onCommit` lands,
    /// misrouting that commit into the next segment's row once it finally
    /// resolves. See `SystemTranslationProvider.sendBridgeRequest(isFinal:)`'s
    /// doc.
    @Test func flushDefersItsBoundaryUntilAnEarlierPendingRequestResolves() async throws {
        let provider = SystemTranslationProvider()
        var commits: [String] = []
        var flushBoundaryCount = 0
        provider.onBridgeRequest = { _ in }
        provider.onCommit = { commits.append($0) }
        provider.onFlushBoundary = { flushBoundaryCount += 1 }
        try await provider.start(config: TranslationConfig(targetLanguageCode: "zh-CN", earlyTranslateThreshold: 60))

        provider.feed(String(repeating: "x", count: 60)) // sends an early, non-final request
        provider.flush() // buffer is now empty — must defer, not fire immediately

        #expect(flushBoundaryCount == 0)
        #expect(commits.isEmpty)

        // The early request's result finally arrives.
        provider.receiveResult("早期翻译", isFinal: false)

        #expect(commits == ["早期翻译"])
        #expect(flushBoundaryCount == 1) // the deferred boundary fires now, not before
    }

    @Test func updateEarlyTranslateThresholdTakesEffectMidSession() async throws {
        let provider = SystemTranslationProvider()
        var requests: [TranslationBridgeRequest] = []
        provider.onBridgeRequest = { requests.append($0) }
        try await provider.start(config: TranslationConfig(targetLanguageCode: "zh-CN", earlyTranslateThreshold: 400))

        provider.feed(String(repeating: "x", count: 60))
        #expect(requests.isEmpty) // still under the much higher initial threshold

        provider.updateEarlyTranslateThreshold(60)
        provider.feed("y")
        #expect(requests.count == 1)
    }
}
