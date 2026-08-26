import Foundation
import LocalAuthentication
import Security

public struct VolcengineVoiceCredentials: Codable, Equatable, Sendable {
    public var appID: String
    public var accessToken: String
    public var asrResourceID: String
    public var ttsResourceID: String
    public var ttsVoiceType: String
    public var ttsCluster: String

    public init(
        appID: String,
        accessToken: String,
        asrResourceID: String,
        ttsResourceID: String,
        ttsVoiceType: String,
        ttsCluster: String = ""
    ) {
        self.appID = appID
        self.accessToken = accessToken
        self.asrResourceID = asrResourceID
        self.ttsResourceID = ttsResourceID
        self.ttsVoiceType = ttsVoiceType
        self.ttsCluster = ttsCluster
    }

    public var normalized: Self {
        Self(
            appID: appID.trimmingCharacters(in: .whitespacesAndNewlines),
            accessToken: accessToken.trimmingCharacters(in: .whitespacesAndNewlines),
            asrResourceID: asrResourceID.trimmingCharacters(in: .whitespacesAndNewlines),
            ttsResourceID: ttsResourceID.trimmingCharacters(in: .whitespacesAndNewlines),
            ttsVoiceType: ttsVoiceType.trimmingCharacters(in: .whitespacesAndNewlines),
            ttsCluster: ttsCluster.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    public var missingBaseFields: [String] {
        let value = normalized
        return [
            ("App ID", value.appID),
            ("Access Token", value.accessToken)
        ].compactMap { label, field in field.isEmpty ? label : nil }
    }

    public var isASRComplete: Bool {
        missingBaseFields.isEmpty && !normalized.asrResourceID.isEmpty
    }

    public var isTTSComplete: Bool {
        let value = normalized
        return missingBaseFields.isEmpty && !value.ttsResourceID.isEmpty && !value.ttsVoiceType.isEmpty
    }

    public var isComplete: Bool { isASRComplete && isTTSComplete }

    public var validationErrors: [String] {
        let value = normalized
        var fields = missingBaseFields
        let hasAnyASRValue = !value.asrResourceID.isEmpty
        let hasAnyTTSValue = !value.ttsResourceID.isEmpty || !value.ttsVoiceType.isEmpty || !value.ttsCluster.isEmpty
        if !hasAnyASRValue && !hasAnyTTSValue {
            fields.append("ASR Resource ID 或完整 TTS 配置")
        }
        if hasAnyTTSValue {
            if value.ttsResourceID.isEmpty { fields.append("TTS Resource ID") }
            if value.ttsVoiceType.isEmpty { fields.append("TTS Voice Type") }
        }
        return fields
    }
}

public enum VolcengineCredentialsError: LocalizedError {
    case invalid([String])
    case encodingFailed
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalid(let fields):
            "请填写：\(fields.joined(separator: "、"))"
        case .encodingFailed:
            "无法编码火山引擎语音配置"
        case .keychain(let status):
            "无法访问 macOS Keychain（错误码 \(status)）"
        }
    }
}

public enum KeychainCredentialStatus: Equatable, Sendable {
    case available
    case missing
    case authorizationRequired
    case unavailable
}

public struct VolcengineCredentialsStore: Sendable {
    private let service = "com.tarst.voice.volcengine.v3"
    private let legacyServices = ["com.tarst.voice.volcengine.v2", "com.tarst.voice.volcengine"]
    private let account = "default"

    public init() {}

    public func load(allowInteraction: Bool = true) throws -> VolcengineVoiceCredentials? {
        if let value = try LocalCredentialVault.load(VolcengineVoiceCredentials.self, service: service) {
            return value
        }
        if let value = try load(service: service, allowInteraction: allowInteraction, dataProtection: true) {
            return value
        }
        guard allowInteraction else { return nil }
        for legacyService in legacyServices {
            if let legacy = try load(service: legacyService, allowInteraction: true, dataProtection: false) {
                try save(legacy)
                return legacy
            }
        }
        return nil
    }

    private func load(service: String, allowInteraction: Bool, dataProtection: Bool) throws -> VolcengineVoiceCredentials? {
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
        guard status == errSecSuccess else { throw VolcengineCredentialsError.keychain(status) }
        guard let data = result as? Data else { throw VolcengineCredentialsError.encodingFailed }
        do {
            return try JSONDecoder().decode(VolcengineVoiceCredentials.self, from: data)
        } catch {
            throw VolcengineCredentialsError.encodingFailed
        }
    }

    /// Checks whether a credential exists without requesting a password or showing UI.
    /// This is safe to call while an AppKit menu is tracking.
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

    public func save(_ credentials: VolcengineVoiceCredentials) throws {
        let value = credentials.normalized
        guard value.validationErrors.isEmpty else {
            throw VolcengineCredentialsError.invalid(value.validationErrors)
        }
        guard let data = try? JSONEncoder().encode(value) else {
            throw VolcengineCredentialsError.encodingFailed
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
            guard insertStatus == errSecSuccess else {
                throw VolcengineCredentialsError.keychain(insertStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw VolcengineCredentialsError.keychain(updateStatus)
        }
    }

    public func delete() throws {
        try LocalCredentialVault.delete(service: service)
        for (service, dataProtection) in [(service, true)] + legacyServices.map({ ($0, false) }) {
            let status = SecItemDelete(baseQuery(service: service, dataProtection: dataProtection) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
                throw VolcengineCredentialsError.keychain(status)
            }
        }
    }

    private func baseQuery(service: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
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
