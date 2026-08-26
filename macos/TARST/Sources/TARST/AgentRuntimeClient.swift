import Foundation

public enum AgentRuntimeClientError: LocalizedError {
    case missingNodeRuntime
    case missingRuntimeEntry
    case alreadyRunning
    case notRunning
    case missingCredentials
    case failedToStart(String)
    case invalidEvent

    public var errorDescription: String? {
        switch self {
        case .missingNodeRuntime: "未找到 Node.js 运行时。"
        case .missingRuntimeEntry: "未找到 TARST Agent Runtime。"
        case .alreadyRunning: "Agent Runtime 已在运行。"
        case .notRunning: "Agent Runtime 尚未运行。"
        case .missingCredentials: "未在 Keychain 找到 MiniMax API Key。"
        case .failedToStart: "Agent Runtime 启动失败。"
        case .invalidEvent: "Agent Runtime 返回了无法识别的事件。"
        }
    }
}

/// A JSON-Lines bridge to the local Node Agent Runtime. The credential is read from
/// Keychain by Swift and written once to the child's stdin; it is never placed in
/// process arguments, environment variables, application storage, or diagnostics.
public final class AgentRuntimeClient {
    public enum Event: Sendable {
        case ready
        case configured(provider: String)
        case streamDiagnostic(sessionID: UUID, turnID: UUID, generationID: UUID, fields: [String: AnySendable])
        case textDelta(sessionID: UUID, turnID: UUID, generationID: UUID, text: String)
        case textCompleted(sessionID: UUID, turnID: UUID, generationID: UUID, text: String)
        case completed(sessionID: UUID, turnID: UUID, generationID: UUID)
        case cancelled(sessionID: UUID, turnID: UUID, generationID: UUID)
        case failed(code: String, message: String)
    }

    public var onEvent: ((Event) -> Void)?

    private let nodeExecutable: URL?
    private let runtimeEntry: URL
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let error = Pipe()
    private var stdoutBuffer = Data()

    public init(nodeExecutable: URL? = TARSTPaths.nodeExecutable, runtimeEntry: URL = TARSTPaths.agentRuntimeEntry) {
        self.nodeExecutable = nodeExecutable
        self.runtimeEntry = runtimeEntry
    }

    deinit { stop() }

    public func startUsingStoredCredentials(provider: String = "minimax_m2_her") throws {
        guard let credentials = try MiniMaxCredentialsStore().load(), credentials.isComplete else {
            throw AgentRuntimeClientError.missingCredentials
        }
        try start(credentials: credentials.normalized, provider: provider)
    }

    public func start(credentials: MiniMaxCredentials, provider: String = "minimax_m2_her") throws {
        guard !process.isRunning else { throw AgentRuntimeClientError.alreadyRunning }
        guard let nodeExecutable else { throw AgentRuntimeClientError.missingNodeRuntime }
        guard FileManager.default.isExecutableFile(atPath: nodeExecutable.path) else { throw AgentRuntimeClientError.missingNodeRuntime }
        guard FileManager.default.fileExists(atPath: runtimeEntry.path) else { throw AgentRuntimeClientError.missingRuntimeEntry }
        guard credentials.isComplete else { throw AgentRuntimeClientError.missingCredentials }

        process.executableURL = nodeExecutable
        process.arguments = [runtimeEntry.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeOutput(handle.availableData)
        }
        // Provider failures are sent as structured stdout events. Deliberately do
        // not surface raw stderr, because it could contain implementation details.
        error.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        do {
            try process.run()
            try write(RuntimeConfiguration(provider: provider, apiKey: credentials.apiKey))
        } catch {
            stop()
            throw AgentRuntimeClientError.failedToStart(error.localizedDescription)
        }
    }

    public func submit(text: String, sessionID: UUID, turnID: UUID, generationID: UUID) throws {
        try write(TurnStart(
            sessionID: sessionID.uuidString,
            turnID: turnID.uuidString,
            generationID: generationID.uuidString,
            text: text
        ))
    }

    public func cancel(generationID: UUID) throws {
        try write(GenerationCancel(generationID: generationID.uuidString))
    }

    public func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
        input.fileHandleForWriting.closeFile()
        if process.isRunning { process.terminate() }
    }

    private func write<T: Encodable>(_ event: T) throws {
        guard process.isRunning else { throw AgentRuntimeClientError.notRunning }
        var data = try JSONEncoder().encode(event)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
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
              let type = object["type"] as? String else {
            onEvent?(.failed(code: "invalid_runtime_event", message: AgentRuntimeClientError.invalidEvent.localizedDescription))
            return
        }
        switch type {
        case "runtime.ready": onEvent?(.ready)
        case "runtime.configured":
            onEvent?(.configured(provider: object["provider"] as? String ?? "unknown"))
        case "agent.text_delta", "agent.text_completed":
            guard let identifiers = identifiers(from: object), let text = object["text"] as? String else {
                onEvent?(.failed(code: "invalid_runtime_event", message: AgentRuntimeClientError.invalidEvent.localizedDescription)); return
            }
            let event: Event = type == "agent.text_delta"
                ? .textDelta(sessionID: identifiers.0, turnID: identifiers.1, generationID: identifiers.2, text: text)
                : .textCompleted(sessionID: identifiers.0, turnID: identifiers.1, generationID: identifiers.2, text: text)
            onEvent?(event)
        case "agent.stream_diagnostic":
            guard let identifiers = identifiers(from: object), let fields = object["fields"] as? [String: Any] else {
                onEvent?(.failed(code: "invalid_runtime_event", message: AgentRuntimeClientError.invalidEvent.localizedDescription)); return
            }
            onEvent?(.streamDiagnostic(
                sessionID: identifiers.0,
                turnID: identifiers.1,
                generationID: identifiers.2,
                fields: fields.mapValues(AnySendable.init)
            ))
        case "agent.completed", "agent.cancelled":
            guard let identifiers = identifiers(from: object) else {
                onEvent?(.failed(code: "invalid_runtime_event", message: AgentRuntimeClientError.invalidEvent.localizedDescription)); return
            }
            onEvent?(type == "agent.completed"
                ? .completed(sessionID: identifiers.0, turnID: identifiers.1, generationID: identifiers.2)
                : .cancelled(sessionID: identifiers.0, turnID: identifiers.1, generationID: identifiers.2))
        case "agent.failed":
            onEvent?(.failed(
                code: object["code"] as? String ?? "runtime_failure",
                message: object["safe_message"] as? String ?? "Agent Runtime 无法完成本轮请求。"
            ))
        default:
            onEvent?(.failed(code: "invalid_runtime_event", message: AgentRuntimeClientError.invalidEvent.localizedDescription))
        }
    }

    private func identifiers(from object: [String: Any]) -> (UUID, UUID, UUID)? {
        guard let session = object["session_id"] as? String, let sessionID = UUID(uuidString: session),
              let turn = object["turn_id"] as? String, let turnID = UUID(uuidString: turn),
              let generation = object["generation_id"] as? String, let generationID = UUID(uuidString: generation) else { return nil }
        return (sessionID, turnID, generationID)
    }
}

public struct AnySendable: @unchecked Sendable {
    public let value: Any
    public init(_ value: Any) { self.value = value }
}

private struct RuntimeConfiguration: Encodable {
    let type = "runtime.configure"
    let provider: String
    let apiKey: String
    enum CodingKeys: String, CodingKey { case type, provider; case apiKey = "api_key" }
}

private struct TurnStart: Encodable {
    let type = "turn.start"
    let sessionID: String
    let turnID: String
    let generationID: String
    let text: String
    enum CodingKeys: String, CodingKey { case type, text; case sessionID = "session_id"; case turnID = "turn_id"; case generationID = "generation_id" }
}

private struct GenerationCancel: Encodable {
    let type = "generation.cancel"
    let generationID: String
    enum CodingKeys: String, CodingKey { case type; case generationID = "generation_id" }
}
