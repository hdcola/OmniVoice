import Foundation
import Security

/// Where the API key lives. Never UserDefaults.
public protocol PolishCredentialStore: Sendable {
    func apiKey() -> String?
    func setAPIKey(_ key: String?)
}

public extension PolishCredentialStore {
    var hasAPIKey: Bool { !(apiKey() ?? "").isEmpty }
}

/// The macOS Keychain, one generic-password item.
public struct KeychainPolishCredentialStore: PolishCredentialStore {
    private let service: String
    private let account = "polish-api-key"

    public init(service: String = "org.hdcola.omnivoice.polish") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func apiKey() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setAPIKey(_ key: String?) {
        SecItemDelete(query as CFDictionary)
        guard let key, !key.isEmpty, let data = key.data(using: .utf8) else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// For tests.
public final class InMemoryPolishCredentialStore: PolishCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    public init(key: String? = nil) { self.key = key }

    public func apiKey() -> String? { lock.withLock { key } }
    public func setAPIKey(_ key: String?) { lock.withLock { self.key = key } }
}
