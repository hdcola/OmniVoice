import Foundation
import Testing
@testable import OmniVoiceCore

@Suite("OpenAICompatiblePolisher")
struct OpenAICompatiblePolisherTests {
    private final class Captured: @unchecked Sendable {
        var request: URLRequest?
    }

    private func response(_ status: Int, _ body: String, url: URL = URL(string: "https://x.test")!) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private func polisher(
        baseURL: String = "https://api.test/v1", apiKey: String? = "sk-1", timeout: TimeInterval = 8,
        transport: @escaping OpenAICompatiblePolisher.Transport
    ) -> OpenAICompatiblePolisher {
        OpenAICompatiblePolisher(
            baseURL: URL(string: baseURL)!, model: "m1", apiKey: apiKey, style: .clean, extra: "",
            timeout: timeout, transport: transport)
    }

    private func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let ok = #"{"choices":[{"message":{"role":"assistant","content":"整理好的文字。"}}]}"#

    @Test("the request carries model, temperature, max tokens and both messages")
    func requestBody() async throws {
        let captured = Captured()
        let text = "你好世界"
        let result = try await polisher { request in
            captured.request = request
            return self.response(200, self.ok)
        }.polish(text)
        #expect(result == "整理好的文字。")

        let request = try #require(captured.request)
        #expect(request.url?.absoluteString == "https://api.test/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")
        #expect(request.timeoutInterval == 8)
        let body = try bodyJSON(request)
        #expect(body["model"] as? String == "m1")
        #expect(body["temperature"] as? Double == 0.3)
        #expect(body["stream"] as? Bool == false)
        #expect(body["max_tokens"] as? Int == text.count * 2 + 256)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(messages[1]["content"] == "<transcription>你好世界</transcription>")
    }

    @Test("max tokens is capped at 4096")
    func maxTokensCap() async throws {
        let captured = Captured()
        _ = try await polisher { request in
            captured.request = request
            return self.response(200, self.ok)
        }.polish(String(repeating: "字", count: 5000))
        let body = try bodyJSON(try #require(captured.request))
        #expect(body["max_tokens"] as? Int == 4096)
    }

    @Test("a trailing slash on the Base URL and no key (local) both work")
    func localNoKey() async throws {
        let captured = Captured()
        _ = try await polisher(baseURL: "http://localhost:11434/v1/", apiKey: nil) { request in
            captured.request = request
            return self.response(200, self.ok)
        }.polish("x")
        #expect(captured.request?.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(captured.request?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("non-2xx statuses map to errors, 401/403 to unauthorized")
    func httpErrors() async {
        for (status, expected) in [(401, PolishError.unauthorized), (403, .unauthorized), (500, .http(500)), (429, .http(429))] {
            await #expect(throws: PolishError.self) {
                _ = try await polisher { _ in self.response(status, "{}") }.polish("x")
            }
            do {
                _ = try await polisher { _ in self.response(status, "{}") }.polish("x")
            } catch {
                #expect(error as? PolishError == expected)
            }
        }
    }

    @Test("a URL timeout becomes .timeout, other failures .network")
    func transportErrors() async {
        do {
            _ = try await polisher { _ in throw URLError(.timedOut) }.polish("x")
            Issue.record("expected a throw")
        } catch { #expect(error as? PolishError == .timeout) }
        do {
            _ = try await polisher { _ in throw URLError(.notConnectedToInternet) }.polish("x")
            Issue.record("expected a throw")
        } catch { #expect(error as? PolishError == .network) }
    }

    @Test("empty or malformed content is .emptyResponse")
    func emptyContent() async {
        for body in [#"{"choices":[{"message":{"content":"  "}}]}"#, #"{"choices":[]}"#, "not json"] {
            do {
                _ = try await polisher { _ in self.response(200, body) }.polish("x")
                Issue.record("expected a throw")
            } catch { #expect(error as? PolishError == .emptyResponse) }
        }
    }

    @Test("testConnection sends a tiny request and reports the time")
    func connection() async throws {
        let captured = Captured()
        let elapsed = try await polisher { request in
            captured.request = request
            return self.response(200, self.ok)
        }.testConnection()
        #expect(elapsed >= 0)
        let body = try bodyJSON(try #require(captured.request))
        #expect(body["max_tokens"] as? Int == 8)
    }

    @Test("reasoning_effort none is sent, except to api.openai.com")
    func reasoningEffort() async throws {
        for (url, expected) in [("http://127.0.0.1:1234/v1", true), ("https://api.openai.com/v1", false)] {
            let captured = Captured()
            _ = try await polisher(baseURL: url) { request in
                captured.request = request
                return self.response(200, self.ok)
            }.polish("x")
            let body = try bodyJSON(try #require(captured.request))
            #expect((body["reasoning_effort"] as? String == "none") == expected)
        }
    }

    @Test("a 400 is retried once without reasoning_effort")
    func retryWithoutReasoning() async throws {
        let bodies = Captured2()
        let result = try await polisher(baseURL: "https://other.test/v1") { request in
            let sent = try self.bodyJSON(request)
            bodies.append(sent["reasoning_effort"] != nil)
            return sent["reasoning_effort"] != nil ? self.response(400, "{}") : self.response(200, self.ok)
        }.polish("x")
        #expect(result == "整理好的文字。")
        #expect(bodies.values == [true, false])
    }

    @Test("a 400 on api.openai.com is not retried")
    func noRetryOnOpenAI() async {
        let bodies = Captured2()
        do {
            _ = try await polisher(baseURL: "https://api.openai.com/v1") { _ in
                bodies.append(false)
                return self.response(400, "{}")
            }.polish("x")
            Issue.record("expected a throw")
        } catch { #expect(error as? PolishError == .http(400)) }
        #expect(bodies.values.count == 1)
    }

    @Test("empty content cut off by max_tokens is .truncated")
    func truncated() async {
        let body = #"{"choices":[{"finish_reason":"length","message":{"content":"","reasoning_content":"thinking"}}]}"#
        do {
            _ = try await polisher { _ in self.response(200, body) }.testConnection()
            Issue.record("expected a throw")
        } catch { #expect(error as? PolishError == .truncated) }
    }

    @Test("<think> blocks are stripped, and an unterminated one leaves nothing")
    func thinkBlocks() async throws {
        let withThink = #"{"choices":[{"message":{"content":"<think>hmm</think>\n你好。"}}]}"#
        #expect(try await polisher { _ in self.response(200, withThink) }.polish("x") == "你好。")
        let open = #"{"choices":[{"finish_reason":"length","message":{"content":"<think>never ends"}}]}"#
        do {
            _ = try await polisher { _ in self.response(200, open) }.polish("x")
            Issue.record("expected a throw")
        } catch { #expect(error as? PolishError == .truncated) }
    }

    private final class Captured2: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Bool] = []
        func append(_ value: Bool) { lock.lock(); items.append(value); lock.unlock() }
        var values: [Bool] { lock.lock(); defer { lock.unlock() }; return items }
    }
}
