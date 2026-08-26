import Foundation

/// Writes numeric detector telemetry only. Raw PCM and speech content never enter
/// this recorder. Each session is a local JSONL file that can be deleted directly.
public final class DiagnosticsRecorder {
    private let queue = DispatchQueue(label: "com.tarst.diagnostics")
    private let directory: URL
    private var handle: FileHandle?
    private var startedAt: TimeInterval = 0
    private var fileURL: URL?

    public init(directory: URL = TARSTPaths.diagnosticsDirectory) {
        self.directory = directory
    }

    public var isRecording: Bool { queue.sync { handle != nil } }

    public func start(metadata: [String: Any]) throws -> URL {
        try queue.sync {
            if let fileURL, handle != nil { return fileURL }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory
                .appending(path: "diagnostics-\(formatter.string(from: Date())).jsonl")
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw NSError(
                    domain: "TARST.Diagnostics",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "无法创建本地诊断文件。"]
                )
            }
            handle = try FileHandle(forWritingTo: destination)
            fileURL = destination
            startedAt = ProcessInfo.processInfo.systemUptime
            write(type: "session_started", fields: ["metadata": metadata])
            return destination
        }
    }

    public func recordFrame(wakeScores: [Float], voiceProbability: Float, keywordIndex: Int?) {
        queue.async { [weak self] in
            self?.write(type: "frame", fields: [
                "elapsed_ms": self?.elapsedMilliseconds ?? 0,
                "tarst_score": wakeScores.indices.contains(0) ? wakeScores[0] : 0,
                "hey_tarst_score": wakeScores.indices.contains(1) ? wakeScores[1] : 0,
                "vad_probability": voiceProbability,
                "keyword_index": keywordIndex.map { $0 as Any } ?? NSNull(),
            ])
        }
    }

    public func recordEvent(_ name: String, fields: [String: Any] = [:]) {
        queue.async { [weak self] in
            guard let self else { return }
            var payload = fields
            payload["elapsed_ms"] = elapsedMilliseconds
            write(type: name, fields: payload)
        }
    }

    public func stop() {
        queue.sync {
            guard handle != nil else { return }
            write(type: "session_stopped", fields: ["elapsed_ms": elapsedMilliseconds])
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
            fileURL = nil
        }
    }

    private var elapsedMilliseconds: Int {
        Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
    }

    private func write(type: String, fields: [String: Any]) {
        guard let handle else { return }
        var object = fields
        object["type"] = type
        object["timestamp"] = ISO8601DateFormatter().string(from: Date())
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? handle.write(contentsOf: data)
        try? handle.write(contentsOf: Data([10]))
    }
}
