import Foundation

enum LocalVoiceDetectorError: LocalizedError {
    case missingRuntime
    case failedToStart(String)
    case invalidEvent

    var errorDescription: String? {
        switch self {
        case .missingRuntime: "本地 openWakeWord / Silero VAD 运行环境尚未安装。"
        case .failedToStart(let detail): "本地语音检测器启动失败：\(detail)"
        case .invalidEvent: "本地语音检测器返回了无法识别的事件。"
        }
    }
}

/// Bridges the Swift menu-bar app to a local-only Python worker. Swift remains the sole
/// microphone owner; frames leave the process only through this machine's stdin pipe.
final class LocalVoiceDetector {
    enum Event {
        case prediction(keywordIndex: Int?, voiceProbability: Float)
        case error(String)
    }

    var onEvent: ((Event) -> Void)?
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let error = Pipe()
    private var stdoutBuffer = Data()

    init() throws {
        guard TARSTPaths.isConfigured else { throw LocalVoiceDetectorError.missingRuntime }
        process.executableURL = TARSTPaths.python
        process.arguments = [
            TARSTPaths.detectorWorker.path,
            "--model", TARSTPaths.tarstKeyword.path,
            "--model", TARSTPaths.heyTarstKeyword.path
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeOutput(handle.availableData)
        }
        error.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let message = String(data: handle.availableData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !message.isEmpty { self?.onEvent?(.error(message)) }
        }
        do {
            try process.run()
        } catch {
            throw LocalVoiceDetectorError.failedToStart(error.localizedDescription)
        }
    }

    deinit { stop() }

    func process(_ frame: ArraySlice<Int16>) throws {
        guard process.isRunning else { throw LocalVoiceDetectorError.failedToStart("检测器进程已退出") }
        var samples = Array(frame)
        let data = samples.withUnsafeMutableBytes { Data($0) }
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
        input.fileHandleForWriting.closeFile()
        if process.isRunning { process.terminate() }
    }

    private func consumeOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 10) {
            let line = stdoutBuffer.prefix(upTo: newline)
            stdoutBuffer.removeSubrange(...newline)
            decode(line)
        }
    }

    private func decode(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let voice = object["voice_probability"] as? NSNumber else {
            onEvent?(.error(LocalVoiceDetectorError.invalidEvent.localizedDescription))
            return
        }
        let keyword = (object["keyword_index"] as? NSNumber)?.intValue
        onEvent?(.prediction(keywordIndex: keyword, voiceProbability: voice.floatValue))
    }
}
