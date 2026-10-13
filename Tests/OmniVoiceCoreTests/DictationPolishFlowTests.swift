import Foundation
import Testing
@testable import OmniVoiceCore

@Suite("DictationPolishFlow")
struct DictationPolishFlowTests {
    private final class Spy: TextPolisher, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var inputs: [String] = []
        let handler: @Sendable (String) async throws -> String
        init(_ handler: @escaping @Sendable (String) async throws -> String) { self.handler = handler }
        var calls: Int { lock.withLock { inputs.count } }
        func polish(_ text: String) async throws -> String {
            lock.withLock { inputs.append(text) }
            return try await handler(text)
        }
    }

    private let long = "嗯那个我明天下午三点有个会就是说可能没法吃饭了"

    private func settings(enabled: Bool = true, timeout: Int = 8) -> PolishSettings {
        var s = PolishSettings()
        s.isEnabled = enabled
        s.timeoutSeconds = timeout
        return s
    }

    private func flow(_ s: PolishSettings, key: Bool = true, spy: Spy) -> DictationPolishFlow {
        DictationPolishFlow(settings: s, hasAPIKey: key) { _ in spy }
    }

    @Test("off: the polisher is never called")
    func off() async {
        let spy = Spy { $0 }
        let result = await flow(settings(enabled: false), spy: spy).run(long)
        #expect(result.text == long)
        #expect(result.outcome == .skipped(.disabled))
        #expect(spy.calls == 0)
    }

    @Test("incomplete configuration types the original")
    func notConfigured() async {
        let spy = Spy { $0 }
        let result = await flow(settings(), key: false, spy: spy).run(long)
        #expect(result.outcome == .skipped(.notConfigured))
        #expect(spy.calls == 0)
    }

    @Test("short text is skipped, CJK by character and Latin by word")
    func tooShort() async {
        let spy = Spy { $0 }
        let f = flow(settings(), spy: spy)
        #expect(await f.run("好的谢谢").outcome == .skipped(.tooShort))
        #expect(await f.run("send it now please").outcome == .skipped(.tooShort))
        #expect(spy.calls == 0)
        #expect(DictationPolishFlow.units(in: "hello world, this is a test of the thing") == 9)
        #expect(DictationPolishFlow.units(in: long) >= 8)
    }

    @Test("a good output replaces the text")
    func polished() async {
        let spy = Spy { _ in "我明天下午三点有个会，可能没法吃饭了。" }
        let result = await flow(settings(), spy: spy).run(long)
        #expect(result.text == "我明天下午三点有个会，可能没法吃饭了。")
        #expect(result.outcome == .polished)
    }

    @Test("a throwing polisher returns the original with the error")
    func failure() async {
        let spy = Spy { _ in throw PolishError.http(500) }
        let result = await flow(settings(), spy: spy).run(long)
        #expect(result.text == long)
        #expect(result.outcome == .failed(.http(500)))
    }

    @Test("an output the guard rejects returns the original")
    func rejected() async {
        let spy = Spy { text in "好的，以下是整理后的文本：" + text }
        let result = await flow(settings(), spy: spy).run(long)
        #expect(result.text == long)
        #expect(result.outcome == .failed(.rejected))
    }

    @Test("entities are masked before the request and restored after")
    func masking() async {
        let text = "你帮我打开 https://example.com/a?b=1 然后运行 --dry-run 看看结果怎么样"
        let spy = Spy { "请帮我打开 \($0.contains("⟦0⟧") ? "⟦0⟧" : "")，然后运行 ⟦1⟧，看看结果怎么样。" }
        let result = await flow(settings(), spy: spy).run(text)
        #expect(spy.inputs.first?.contains("https://example.com") == false)
        #expect(spy.inputs.first?.contains("⟦0⟧") == true)
        #expect(result.outcome == .polished)
        #expect(result.text.contains("https://example.com/a?b=1"))
        #expect(result.text.contains("--dry-run"))
        #expect(!result.text.contains("⟦"))
    }

    @Test("a lost placeholder is rejected")
    func lostPlaceholder() async {
        let text = "你帮我打开 https://example.com/a?b=1 然后看看结果怎么样吧"
        let spy = Spy { _ in "请帮我打开网址，然后看看结果怎么样吧。" }
        let result = await flow(settings(), spy: spy).run(text)
        #expect(result.text == text)
        #expect(result.outcome == .failed(.rejected))
    }

    @Test("the timeout falls back to the original")
    func timeout() async {
        let spy = Spy { _ in
            try await Task.sleep(for: .seconds(30))
            return "x"
        }
        var s = settings()
        s.timeoutSeconds = 3
        let started = Date()
        let result = await flow(s, spy: spy).run(long)
        #expect(result.outcome == .failed(.timeout))
        #expect(result.text == long)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("cancelling (Esc) returns the original at once")
    func cancelled() async {
        let spy = Spy { _ in
            try await Task.sleep(for: .seconds(30))
            return "x"
        }
        let f = flow(settings(), spy: spy)
        let long = self.long
        let task = Task { await f.run(long) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.value
        #expect(result.outcome == .cancelled)
        #expect(result.text == long)
    }

    @Test("polish runs before translation: the translated text is the polished one")
    func orderBeforeTranslation() async {
        // The controller feeds `Result.text` to the translation review, so
        // what the review shows as the original is the polished text.
        let spy = Spy { _ in "我明天下午三点有个会，可能没法吃饭了。" }
        let result = await flow(settings(), spy: spy).run(long)
        let reviewOriginal = result.text
        #expect(reviewOriginal != long)
        #expect(reviewOriginal == "我明天下午三点有个会，可能没法吃饭了。")
    }
}
