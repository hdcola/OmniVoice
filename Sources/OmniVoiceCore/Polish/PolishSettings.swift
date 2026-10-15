import Foundation

/// How much the LLM may rewrite what was dictated.
public enum PolishStyle: String, CaseIterable, Identifiable, Sendable {
    /// Punctuation, sentence breaks and obvious filler words only.
    case minimal
    /// Light tidy-up into natural text (the default).
    case clean
    /// Parallel items become a numbered list.
    case structured
    /// A concise work-chat tone.
    case professional

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .minimal: return "保持原话"
        case .clean: return "清爽"
        case .structured: return "结构化"
        case .professional: return "正式"
        }
    }

    /// The `[STYLE]` paragraph of the system prompt.
    var instruction: String {
        switch self {
        case .minimal: return "只加标点和断句、删明显口癖，不改写措辞和顺序。"
        case .clean: return "轻度整理成自然、可直接使用的文字，保持语气和信息量。"
        case .structured: return "两项以上并列内容整理成编号列表；不强行给单个想法加结构。"
        case .professional: return "整理成简洁的工作沟通语气，保留事实和意图，不加客套话。"
        }
    }
}

/// A service whose Base URL and default model are filled in for the user.
public enum PolishPreset: String, CaseIterable, Identifiable, Sendable {
    case openAI, deepSeek, zhipu, ollama, custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .deepSeek: return "DeepSeek"
        case .zhipu: return "智谱"
        case .ollama: return "Ollama（本地）"
        case .custom: return "自定义"
        }
    }

    public var baseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
        case .ollama: return "http://localhost:11434/v1"
        case .custom: return ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .openAI: return "gpt-4o-mini"
        case .deepSeek: return "deepseek-chat"
        case .zhipu: return "glm-4-flash"
        case .ollama: return "qwen2.5:7b"
        case .custom: return ""
        }
    }
}

/// The user's polish configuration, minus the API key (that lives in the
/// Keychain — see `PolishCredentialStore`).
public struct PolishSettings: Equatable, Sendable {
    public static let enabledKey = "org.hdcola.omnivoice.dictation.polish.enabled"
    public static let presetKey = "org.hdcola.omnivoice.dictation.polish.preset"
    public static let baseURLKey = "org.hdcola.omnivoice.dictation.polish.baseURL"
    public static let modelKey = "org.hdcola.omnivoice.dictation.polish.model"
    public static let styleKey = "org.hdcola.omnivoice.dictation.polish.style"
    public static let extraKey = "org.hdcola.omnivoice.dictation.polish.extra"
    public static let timeoutKey = "org.hdcola.omnivoice.dictation.polish.timeout"
    public static let acknowledgedKey = "org.hdcola.omnivoice.dictation.polish.acknowledged"

    public static let timeoutRange: ClosedRange<Int> = 3...30
    public static let defaultTimeout = 8
    public static let maxExtraLength = 500

    /// Off until the user opts in; nothing is sent anywhere while it is.
    public var isEnabled = false
    public var preset: PolishPreset = .openAI
    public var baseURL: String = PolishPreset.openAI.baseURL
    /// A model id is a single line; pasted or stored line breaks are dropped
    /// (see `singleLine`), or the service rejects it with a 400.
    public var model: String = PolishPreset.openAI.defaultModel {
        didSet {
            let line = Self.singleLine(model)
            if line != model { model = line }
        }
    }
    public var style: PolishStyle = .clean
    public var extra = ""
    /// Seconds; always within `timeoutRange`.
    public var timeoutSeconds = PolishSettings.defaultTimeout {
        didSet { timeoutSeconds = Self.clampTimeout(timeoutSeconds) }
    }
    /// The user has seen that dictated text is sent to their LLM service.
    public var hasAcknowledgedPrivacy = false

    public init() {}

    /// The first non-empty line of `text`, or `text` itself when it has no
    /// line break — so a model id pasted twice, or with a trailing newline,
    /// still names one model.
    public static func singleLine(_ text: String) -> String {
        guard text.contains(where: \.isNewline) else { return text }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    public static func clampTimeout(_ seconds: Int) -> Int {
        min(max(seconds, timeoutRange.lowerBound), timeoutRange.upperBound)
    }

    /// Settings written by an older version lack these keys: every one falls
    /// back to its default.
    public static func load(from defaults: UserDefaults = .standard) -> PolishSettings {
        var settings = PolishSettings()
        settings.isEnabled = defaults.bool(forKey: enabledKey)
        if let preset = defaults.string(forKey: presetKey).flatMap(PolishPreset.init) { settings.preset = preset }
        if let baseURL = defaults.string(forKey: baseURLKey) { settings.baseURL = baseURL }
        if let model = defaults.string(forKey: modelKey) { settings.model = model }
        if let style = defaults.string(forKey: styleKey).flatMap(PolishStyle.init) { settings.style = style }
        settings.extra = String((defaults.string(forKey: extraKey) ?? "").prefix(maxExtraLength))
        if let timeout = defaults.object(forKey: timeoutKey) as? Int { settings.timeoutSeconds = timeout }
        settings.hasAcknowledgedPrivacy = defaults.bool(forKey: acknowledgedKey)
        return settings
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: Self.enabledKey)
        defaults.set(preset.rawValue, forKey: Self.presetKey)
        defaults.set(baseURL, forKey: Self.baseURLKey)
        defaults.set(model, forKey: Self.modelKey)
        defaults.set(style.rawValue, forKey: Self.styleKey)
        defaults.set(extra, forKey: Self.extraKey)
        defaults.set(timeoutSeconds, forKey: Self.timeoutKey)
        defaults.set(hasAcknowledgedPrivacy, forKey: Self.acknowledgedKey)
    }

    /// Picking a preset fills in its Base URL and model (custom keeps what is typed).
    public mutating func apply(preset: PolishPreset) {
        self.preset = preset
        guard preset != .custom else { return }
        baseURL = preset.baseURL
        model = preset.defaultModel
    }

    /// The Base URL as a URL, when it is http(s) with a host.
    public var endpointBase: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host?.isEmpty == false
        else { return nil }
        return url
    }

    /// Whether the endpoint is on this Mac — no key needed, plain http is fine.
    public var isLocalEndpoint: Bool {
        guard let host = endpointBase?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// Plain http to somewhere other than this Mac: worth a warning.
    public var usesInsecureRemoteEndpoint: Bool {
        endpointBase?.scheme?.lowercased() == "http" && !isLocalEndpoint
    }

    /// Everything needed to make a request is filled in.
    public func isConfigured(hasAPIKey: Bool) -> Bool {
        guard endpointBase != nil,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return hasAPIKey || isLocalEndpoint
    }
}
