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

    /// api.openai.com has its own dialect: `max_completion_tokens` instead of
    /// `max_tokens`, and no `temperature` on its reasoning models.
    private var isDirectOpenAI: Bool {
        baseURL.host?.lowercased() == "api.openai.com"
    }

    /// OpenAI's reasoning families (gpt-5, o1, o3, o4): reasoning tokens count
    /// against the token limit, and sampling controls are rejected.
    private var isOpenAIReasoningModel: Bool {
        let name = model.trimmingCharacters(in: .whitespaces).lowercased()
        return name.hasPrefix("gpt-5")
            || ["o1", "o3", "o4"].contains { name == $0 || name.hasPrefix($0 + "-") }
    }

    /// Fields that switch a thinking model's reasoning off (or down). Polishing
    /// needs none, and thinking tokens would otherwise eat the token limit and
    /// leave `content` empty. They are optional: if a service rejects them
    /// with a 400, the request is retried without.
    private var thinkingControls: [String: Any] {
        if isDirectOpenAI {
            // "none" is not accepted by every OpenAI reasoning model; "low" is.
            return isOpenAIReasoningModel ? ["reasoning_effort": "low"] : [:]
        }
        var controls: [String: Any] = ["reasoning_effort": "none"]
        // GLM-4.5 and later think by default and ignore reasoning_effort.
        if model.lowercased().hasPrefix("glm-") { controls["thinking"] = ["type": "disabled"] }
        return controls
    }

    private func complete(messages: [PolishMessage], maxTokens: Int) async throws -> String {
        let controls = thinkingControls
        do {
            return try await send(messages: messages, maxTokens: maxTokens, extras: controls)
        } catch PolishError.http(400) where !controls.isEmpty {
            return try await send(messages: messages, maxTokens: maxTokens, extras: [:])
        }
    }

    private func send(messages: [PolishMessage], maxTokens: Int, extras: [String: Any]) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        if isDirectOpenAI {
            // Reasoning models spend this limit on thinking too, so give it
            // headroom; it is a ceiling, only what is generated is billed.
            body["max_completion_tokens"] = isOpenAIReasoningModel ? 4096 : maxTokens
            if !isOpenAIReasoningModel { body["temperature"] = 0.3 }
        } else {
            body["max_tokens"] = maxTokens
            body["temperature"] = 0.3
        }
        body.merge(extras) { _, new in new }
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
