import Foundation

public enum TARSTPaths {
    public static var applicationSupport: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let path = root.appending(path: "TARST", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    public static var picovoiceDirectory: URL {
        let path = applicationSupport.appending(path: "Picovoice", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    public static var tarstKeyword: URL { applicationSupport.appending(path: "TARST.ppn") }
    public static var heyTarstKeyword: URL { applicationSupport.appending(path: "Hey-TARST.ppn") }
    public static var porcupineModel: URL { picovoiceDirectory.appending(path: "porcupine_params.pv") }
    public static var porcupineLibrary: URL { picovoiceDirectory.appending(path: "libpv_porcupine.dylib") }
    public static var cobraLibrary: URL { picovoiceDirectory.appending(path: "libpv_cobra.dylib") }

    public static var isPicovoiceRuntimeInstalled: Bool {
        [porcupineModel, porcupineLibrary, cobraLibrary].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static var isConfigured: Bool {
        KeychainStore.readAccessKey()?.isEmpty == false
            && [tarstKeyword, heyTarstKeyword].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
            && isPicovoiceRuntimeInstalled
    }

    public static func importKeyword(from source: URL, as destination: URL) throws {
        _ = source.startAccessingSecurityScopedResource()
        defer { source.stopAccessingSecurityScopedResource() }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
