import Foundation
import LocalAuthentication
import Security

public struct MiniMaxCredentials: Codable, Equatable, Sendable {
    public var apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public var normalized: Self {
        Self(apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public var isComplete: Bool { !normalized.apiKey.isEmpty }
}

public enum MiniMaxCredentialsError: LocalizedError {
    case invalid
    case encodingFailed
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalid: "请填写 MiniMax API Key"
        case .encodingFailed: "无法编码 MiniMax 配置"
        case .keychain(let status): "无法访问 macOS Keychain（错误码 \(status)）"
        }
    }
}

public struct MiniMaxCredentialsStore: Sendable {
    private let service = "com.tarst.agent.minimax.v3"
    private let legacyServices = ["com.tarst.agent.minimax.v2", "com.tarst.agent.minimax"]
    private let account = "default"

    public init() {}

    public func load(allowInteraction: Bool = true) throws -> MiniMaxCredentials? {
        if let value = try LocalCredentialVault.load(MiniMaxCredentials.self, service: service) {
            return value
        }
        if let value = try load(service: service, allowInteraction: allowInteraction, dataProtection: true) {
            return value
        }
        // Never touch legacy login-keychain items from a noninteractive probe:
        // SecItemCopyMatching can block in securityd even when UI is forbidden.
        guard allowInteraction else { return nil }
        for legacyService in legacyServices {
            if let legacy = try load(service: legacyService, allowInteraction: true, dataProtection: false) {
                try save(legacy)
                return legacy
            }
        }
        return nil
    }

    private func load(service: String, allowInteraction: Bool, dataProtection: Bool) throws -> MiniMaxCredentials? {
        var query = baseQuery(service: service, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowInteraction {
            query[kSecUseAuthenticationContext as String] = nonInteractiveContext()
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if dataProtection, status == errSecMissingEntitlement { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw MiniMaxCredentialsError.keychain(status)
        }
        guard let value = try? JSONDecoder().decode(MiniMaxCredentials.self, from: data) else {
            throw MiniMaxCredentialsError.encodingFailed
        }
        return value
    }

    /// Checks presence without allowing Keychain to show an authorization dialog.
    public func statusWithoutInteraction() -> KeychainCredentialStatus {
        if LocalCredentialVault.exists(service: service) { return .available }
        let current = statusWithoutInteraction(service: service, dataProtection: true)
        if current == .available { return current }
        for legacyService in legacyServices {
            let legacy = statusWithoutInteraction(service: legacyService, dataProtection: false)
            if legacy != .missing { return legacy }
        }
        return current == .unavailable ? .missing : current
    }

    private func statusWithoutInteraction(service: String, dataProtection: Bool) -> KeychainCredentialStatus {
        var query = baseQuery(service: service, dataProtection: dataProtection)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = nonInteractiveContext()

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return switch status {
        case errSecSuccess: .available
        case errSecItemNotFound: .missing
        case errSecInteractionNotAllowed, errSecAuthFailed: .authorizationRequired
        default: .unavailable
        }
    }

    public func save(_ credentials: MiniMaxCredentials) throws {
        let value = credentials.normalized
        guard value.isComplete else { throw MiniMaxCredentialsError.invalid }
        guard let data = try? JSONEncoder().encode(value) else {
            throw MiniMaxCredentialsError.encodingFailed
        }

        let attributes: [String: Any] = [kSecValueData as String: data]
        let query = baseQuery(service: service, dataProtection: true)
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecMissingEntitlement {
            try LocalCredentialVault.save(value, service: service)
            return
        }
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            if insertStatus == errSecMissingEntitlement {
                try LocalCredentialVault.save(value, service: service)
                return
            }
            guard insertStatus == errSecSuccess else { throw MiniMaxCredentialsError.keychain(insertStatus) }
        } else if updateStatus != errSecSuccess {
            throw MiniMaxCredentialsError.keychain(updateStatus)
        }
    }

    public func delete() throws {
        try LocalCredentialVault.delete(service: service)
        for (service, dataProtection) in [(service, true)] + legacyServices.map({ ($0, false) }) {
            let status = SecItemDelete(baseQuery(service: service, dataProtection: dataProtection) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
                throw MiniMaxCredentialsError.keychain(status)
            }
        }
    }

    private func baseQuery(service: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    private func nonInteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}
