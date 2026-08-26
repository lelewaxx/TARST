import Foundation

public enum TARSTPaths {
    public static var applicationSupport: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let path = root.appending(path: "TARST", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    public static var voiceRuntimeDirectory: URL {
        let path = applicationSupport.appending(path: "VoiceRuntime", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    public static var modelsDirectory: URL {
        let path = applicationSupport.appending(path: "Models", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    public static var diagnosticsDirectory: URL {
        let path = applicationSupport.appending(path: "Diagnostics", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    public static var tarstKeyword: URL { modelsDirectory.appending(path: "TARST.onnx") }
    public static var heyTarstKeyword: URL { modelsDirectory.appending(path: "Hey-TARST.onnx") }
    public static var python: URL { voiceRuntimeDirectory.appending(path: "venv/bin/python3") }
    public static var detectorWorker: URL {
        let bundled = Bundle.main.resourceURL?.appending(path: "local_voice_detector.py")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return voiceRuntimeDirectory.appending(path: "local_voice_detector.py")
    }

    public static var agentRuntimeEntry: URL {
        let bundled = Bundle.main.resourceURL?.appending(path: "agent/src/stdio-runtime.mjs")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "agent/src/stdio-runtime.mjs")
    }

    public static var nodeExecutable: URL? {
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        return candidates.lazy.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    public static var isConfigured: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: detectorWorker.path)
            && [tarstKeyword, heyTarstKeyword].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
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
