import CryptoKit
import Foundation
import IOKit

public enum LocalCredentialVaultError: Error {
    case unavailable
    case invalidData
}

/// Fallback for local self-signed builds, which cannot use the Data Protection
/// Keychain without an Apple-issued TeamIdentifier. Values are AES-GCM encrypted
/// and stored in a 0700 directory as 0600 files. Production Developer-ID builds
/// continue to prefer the system Data Protection Keychain.
public enum LocalCredentialVault {
    public static func load<Value: Decodable>(_ type: Value.Type, service: String) throws -> Value? {
        let url = fileURL(service: service)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let sealed = try Data(contentsOf: url)
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let clear = try? AES.GCM.open(box, using: key(service: service)),
              let value = try? JSONDecoder().decode(Value.self, from: clear) else {
            throw LocalCredentialVaultError.invalidData
        }
        return value
    }

    public static func save<Value: Encodable>(_ value: Value, service: String) throws {
        let directory = directoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let clear = try JSONEncoder().encode(value)
        guard let combined = try AES.GCM.seal(clear, using: key(service: service)).combined else {
            throw LocalCredentialVaultError.unavailable
        }
        let url = fileURL(service: service)
        try combined.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func delete(service: String) throws {
        let url = fileURL(service: service)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public static func exists(service: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(service: service).path)
    }

    private static var directoryURL: URL {
        TARSTPaths.applicationSupport.appending(path: "Credentials", directoryHint: .isDirectory)
    }

    private static func fileURL(service: String) -> URL {
        let safeName = service.replacingOccurrences(of: ".", with: "-")
        return directoryURL.appending(path: "\(safeName).vault")
    }

    private static func key(service: String) -> SymmetricKey {
        let material = "TARST.local-vault.v1|\(deviceIdentifier())|\(getuid())|\(service)"
        return SymmetricKey(data: Data(SHA256.hash(data: Data(material.utf8))))
    }

    private static func deviceIdentifier() -> String {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard entry != 0 else { return "unknown-device" }
        defer { IOObjectRelease(entry) }
        guard let value = IORegistryEntryCreateCFProperty(
            entry,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String else { return "unknown-device" }
        return value
    }
}
