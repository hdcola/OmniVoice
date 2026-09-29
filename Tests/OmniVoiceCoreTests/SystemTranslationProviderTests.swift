import Testing
@testable import OmniVoiceCore

/// Covers `TranslationConfig.earlyTranslateThreshold`'s length-threshold
/// behavior for a one-shot engine — see `SystemTranslationProvider.feed(_:)`'s
/// doc for why a long, pause-free utterance needs an early, non-final bridge
/// request rather than waiting for `flush()` — and the FIFO-ordering fix in
/// `sendBridgeRequest(isFinal:)`'s doc that keeps that safe across multiple
/// utterances.
@MainActor
struct SystemTranslationProviderTests {
    /// Drains `requests` in FIFO order via `receiveResult`, exactly the way
    /// `FloatingTranscriptView`'s `.translationTask` loop consumes
    /// `translationBridgeStream()` — one request's result fully applied
    /// before the next is even considered. Real `translate(_:)` calls are
    /// stubbed by `resolvedText` (`nil` for the empty-text sentinel case,
    /// where the real loop skips the call entirely — see
    /// `TranslationBridgeRequest.text`'s doc).
    private func resolveInOrder(
        _ requests: [TranslationBridgeRequest], on provider: SystemTranslationProvider,
        resolvedText: (TranslationBridgeRequest) -> String
    ) {
        for request in requests {
            provider.receiveResult(request.text.isEmpty ? "" : resolvedText(request), isFinal: request.isFinal)
        }
    }

    /// `pendingBridgeRequestCount` must not leak across a `start(config:)`
    /// (a `.system`-kind provider can be reused across a stop()/start()
    /// cycle, same `reusingLoaded` path a `.model`-kind engine's weights
    /// use to skip reloading) — otherwise a request left unresolved from an
    /// interrupted prior session would make this instance's very first
    /// `flush()` wrongly believe something is still in flight.
    @Test func startResetsPendingBridgeRequestCountLeftOverFromAPriorSession() async throws {
        let provider = SystemTranslationProvider()
        var requests: [TranslationBridgeRequest] = []
        var flushBoundaryCount = 0
        provider.onBridgeRequest = { requests.append($0) }
        provider.onFlushBoundary = { flushBoundaryCount += 1 }
        try await provider.start(config: TranslationConfig(targetLanguageCode: "zh-CN", earlyTranslateThreshold: 60))

        // Leave a request "in flight" (never resolved) — simulating a prior
        // session interrupted before its result came back.
        provider.feed(String(repeating: "x", count: 60))
        #expect(requests.count == 1)

        // A fresh start() (this instance being reused for a new recording)
        // must not carry that stale count forward.
        try await provider.start(config: TranslationConfig(targetLanguageCode: "zh-CN"))
        provider.flush() // buffer is empty — should fire immediately, not send a stale sentinel

        #expect(requests.count == 1) // no new (sentinel) request sent
        #expect(flushBoundaryCount == 1)
    }

    @Test func feedBelowThresholdSendsNoBridgeRequest() async throws {
        let provider = SystemTranslationProvider()
        var requests: [TranslationBridgeRequest] = []
        provider.onBridgeRequest = { requests.append($0) }
        try await provider.start(config: TranslationConfig(targetLanguageCode: "zh-CN", earlyTranslateThreshold: 60))

        provider.feed("short")

        #expect(requests.isEmpty)
    }

    @Test func feedCrossingThresholdSendsANonFinalBridgeRequest() async throws {
        let provider = SystemTranslationProvider()
        var requests: [TranslationBridgeRequest] = []
        provider.onBridgeRequest = { requests.append($0) }
        try await provider.start(config: TranslationConfig(targetLanguageCode: "zh-CN", earlyTranslateThreshold: 60))

        let longText = String(repeating: "x", count: 60)
        provider.feed(longText)

        #expect(requests.count == 1)
        #expect(requests.first?.text == longText)
        #expect(requests.first?.isFinal == false)
    }

    /// `flush()` finding the buffer already drained by an earlier early
    /// request must not just silently do nothing — it still needs to send
    /// an (empty-text) sentinel so the boundary reaches
    /// `receiveResult(_:isFinal:)` in the correct FIFO position, not before
    /// the earlier request resolves. See
    /// `feedCrossingThresholdThenFlushingPreservesOrderAcrossTwoUtterances`
    /// for the full end-to-end scenario this enables.
    @Test func flushAfterAnEarlyRequestDrainedTheBufferSendsAnEmptySentinel() async throws {
        let provider = SystemTranslationProvider()
        var requests: [TranslationBridgeRequest] = []
        provider.onBridgeRequest = { requests.append($0) }
        try await provider.start(config: TranslationConfig(targetLanguageCode: "zh-CN", earlyTranslateThreshold: 60))

        provider.feed(String(repeating: "x", count: 60)) // sends the early request
        provider.flush() // buffer is now empty — must still send a sentinel, not no-op

        #expect(requests.count == 2)
        #expect(requests[1].text.isEmpty)
        #expect(requests[1].isFinal == true)
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

    /// A sentinel's result (empty text) must never reach `onCommit` — it's a
    /// boundary marker, not a (if unhelpful) real translation.
    @Test func receiveResultWithEmptyTextDoesNotCommit() {
        let provider = SystemTranslationProvider()
        var commits: [String] = []
        var flushBoundaryCount = 0
        provider.onCommit = { commits.append($0) }
        provider.onFlushBoundary = { flushBoundaryCount += 1 }

        provider.receiveResult("", isFinal: true)

        #expect(commits.isEmpty)
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

    /// End-to-end regression test for the real bug this whole mechanism
    /// exists to prevent: utterance 1 is long enough to send an early
    /// request, then ends (its `flush()` finds an empty buffer); before
    /// that early request resolves, utterance 2 begins and *also* ends. All
    /// three now-pending requests (early-1, sentinel-1, final-2) must
    /// resolve — in the order they were sent — into exactly two flush
    /// boundaries and two separate commits, never merging utterance 1 and
    /// utterance 2's text into the same row or losing a boundary.
    ///
    /// An earlier fix used a single `pendingFlushBoundary` flag instead of
    /// this FIFO-sentinel design and failed exactly this scenario: it could
    /// only remember "one boundary is owed", not "how many", so utterance
    /// 2's own final request resolving first (in that flag-based version)
    /// swallowed utterance 1's still-deferred boundary — one fewer
    /// `onFlushBoundary` fire than actual utterances, permanently
    /// misaligning every row after it.
    @Test func twoUtterancesInFlightAtOnceEachGetTheirOwnBoundaryAndCommit() async throws {
        let provider = SystemTranslationProvider()
        var requests: [TranslationBridgeRequest] = []
        var commits: [String] = []
        var flushBoundaryCount = 0
        provider.onBridgeRequest = { requests.append($0) }
        provider.onCommit = { commits.append($0) }
        provider.onFlushBoundary = { flushBoundaryCount += 1 }
        try await provider.start(config: TranslationConfig(targetLanguageCode: "zh-CN", earlyTranslateThreshold: 60))

        // Utterance 1: long enough to send an early request, then ends.
        provider.feed(String(repeating: "x", count: 60))
        provider.flush()

        // Utterance 2 begins and ends before utterance 1's early request
        // has resolved (a real, async on-device translate call would still
        // be in flight at this point).
        provider.feed("Next sentence.")
        provider.flush()

        #expect(requests.count == 3) // early-1, sentinel-1, final-2
        #expect(commits.isEmpty)
        #expect(flushBoundaryCount == 0)

        // The bridging view resolves them strictly in the order they were
        // sent (see `resolveInOrder`'s doc).
        resolveInOrder(requests, on: provider) { request in
            request.text == String(repeating: "x", count: 60) ? "早期翻译" : "第二句翻译"
        }

        #expect(commits == ["早期翻译", "第二句翻译"])
        #expect(flushBoundaryCount == 2) // one boundary per utterance, not one total
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
