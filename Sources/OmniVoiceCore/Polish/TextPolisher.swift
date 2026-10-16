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
    /// Cut off by max_tokens before any answer (usually a thinking model).
    case truncated
    /// The output failed `PolishOutputGuard`.
    case rejected

    public var message: String {
        switch self {
        case .notConfigured: return String(localized: "Setup is incomplete")
        case .unauthorized: return String(localized: "Check your API key")
        case .http(let code): return String(localized: "The service returned HTTP \(code)")
        case .timeout: return String(localized: "Request timed out")
        case .network: return String(localized: "Network error")
        case .emptyResponse: return String(localized: "The service returned no content")
        case .truncated: return String(localized: "Output was cut off. This may be a reasoning model: switch to a non-reasoning model, or turn off thinking on the server")
        case .rejected: return String(localized: "Output failed validation")
        }
    }
}

/// Turns raw dictated text into tidier text.
public protocol TextPolisher: Sendable {
    func polish(_ text: String) async throws -> String
}
