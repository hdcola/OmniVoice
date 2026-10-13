import Foundation

/// Why a polish didn't produce text.
public enum PolishError: Error, Equatable, Sendable {
    case notConfigured
    /// 401/403: the key is wrong or lacks access.
    case unauthorized
    case http(Int)
    case timeout
    case network
    case emptyResponse
    /// The output failed `PolishOutputGuard`.
    case rejected

    public var message: String {
        switch self {
        case .notConfigured: return "还没配置完"
        case .unauthorized: return "请检查 API Key"
        case .http(let code): return "服务返回 HTTP \(code)"
        case .timeout: return "请求超时"
        case .network: return "网络错误"
        case .emptyResponse: return "服务没有返回内容"
        case .rejected: return "输出没有通过校验"
        }
    }
}

/// Turns raw dictated text into tidier text.
public protocol TextPolisher: Sendable {
    func polish(_ text: String) async throws -> String
}
