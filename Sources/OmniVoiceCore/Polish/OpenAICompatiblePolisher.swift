import Foundation

/// Sends one non-streaming `chat/completions` request. The transport is
/// injectable so tests never touch the network.
public struct OpenAICompatiblePolisher: TextPolisher {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let urlSessionTransport: Transport = { request in
        try await URLSession.shared.data(for: request)
    }

    public let baseURL: URL
    public let model: String
    public let apiKey: String?
    public let style: PolishStyle
    public let extra: String
    public let timeout: TimeInterval
    private let transport: Transport

    public init(
        baseURL: URL, model: String, apiKey: String?, style: PolishStyle, extra: String,
        timeout: TimeInterval, transport: @escaping Transport = OpenAICompatiblePolisher.urlSessionTransport
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.style = style
        self.extra = extra
        self.timeout = timeout
        self.transport = transport
    }

    public func polish(_ text: String) async throws -> String {
        let messages = PolishPromptBuilder.messages(text: text, style: style, extra: extra)
        return try await complete(messages: messages, maxTokens: min(text.count * 2 + 256, 4096))
    }

    /// A fixed tiny request for Settings' 测试连接; returns the round trip time.
    public func testConnection() async throws -> TimeInterval {
        let start = Date()
        _ = try await complete(messages: [PolishMessage(role: "user", content: "ping")], maxTokens: 8)
        return Date().timeIntervalSince(start)
    }

    /// api.openai.com rejects `reasoning_effort` on non-reasoning models, so it
    /// is never sent there; every other service gets it (and a retry without
    /// it if the service answers 400).
    private var sendsReasoningEffort: Bool {
        baseURL.host?.lowercased() != "api.openai.com"
    }

    private func complete(messages: [PolishMessage], maxTokens: Int) async throws -> String {
        do {
            return try await send(messages: messages, maxTokens: maxTokens, reasoningOff: sendsReasoningEffort)
        } catch PolishError.http(400) where sendsReasoningEffort {
            return try await send(messages: messages, maxTokens: maxTokens, reasoningOff: false)
        }
    }

    private func send(messages: [PolishMessage], maxTokens: Int, reasoningOff: Bool) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = [
            "model": model,
            "temperature": 0.3,
            "max_tokens": maxTokens,
            "stream": false,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        // Thinking models spend max_tokens on reasoning and can return an empty
        // `content`; polishing needs no reasoning.
        if reasoningOff { body["reasoning_effort"] = "none" }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw PolishError.timeout
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw PolishError.network
        }
        guard let http = response as? HTTPURLResponse else { throw PolishError.network }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw PolishError.unauthorized
        default: throw PolishError.http(http.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (object["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any],
              let raw = message["content"] as? String
        else { throw PolishError.emptyResponse }
        let content = Self.strippingThinking(raw)
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Cut off before any answer: typically a thinking model whose
            // reasoning used up max_tokens.
            throw (choice["finish_reason"] as? String) == "length" ? PolishError.truncated : PolishError.emptyResponse
        }
        return content
    }

    /// Some servers inline a thinking model's reasoning as `<think>…</think>`
    /// (an unterminated block means the answer never started).
    static func strippingThinking(_ text: String) -> String {
        guard text.contains("<think>") else { return text }
        var result = text
        while let open = result.range(of: "<think>") {
            if let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                result.removeSubrange(open.lowerBound..<result.endIndex)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
