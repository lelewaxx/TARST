import Darwin
import Foundation
import TARSTCore

@main
enum AgentRuntimeBridgeSmokeTest {
    static func main() {
        let configured = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let deadline = DispatchTime.now() + .seconds(45)
        let client = AgentRuntimeClient()
        let provider = CommandLine.arguments.dropFirst().first ?? "minimax_m2_her"
        var failure: String?
        var firstTextAt: Date?
        var submittedAt: Date?
        var deltaCount = 0

        client.onEvent = { event in
            switch event {
            case .configured(let configuredProvider) where configuredProvider == provider:
                configured.signal()
            case .textDelta:
                deltaCount += 1
                firstTextAt = firstTextAt ?? Date()
            case .completed:
                finished.signal()
            case .failed(let code, let message):
                failure = "\(code): \(message)"
                configured.signal()
                finished.signal()
            default:
                break
            }
        }

        do {
            try client.startUsingStoredCredentials(provider: provider)
            guard configured.wait(timeout: deadline) == .success, failure == nil else {
                throw BridgeSmokeError.configuration(failure)
            }
            submittedAt = Date()
            try client.submit(
                text: "Reply with TARST BRIDGE READY only.",
                sessionID: UUID(),
                turnID: UUID(),
                generationID: UUID()
            )
            guard finished.wait(timeout: deadline) == .success, failure == nil,
                  let firstTextAt, deltaCount > 0 else {
                throw BridgeSmokeError.generation(failure)
            }
            guard let submittedAt else { throw BridgeSmokeError.generation(nil) }
            let firstTextMilliseconds = Int(firstTextAt.timeIntervalSince(submittedAt) * 1_000)
            print("Agent Runtime bridge smoke test passed (\(provider), first text \(firstTextMilliseconds) ms, \(deltaCount) text deltas).")
        } catch {
            fputs("Agent Runtime bridge smoke test failed: \(safeDescription(for: error))\n", stderr)
            exit(1)
        }
    }

    private static func safeDescription(for error: Error) -> String {
        (error as? BridgeSmokeError)?.localizedDescription ?? "无法完成本地 Agent Runtime 测试。"
    }
}

private enum BridgeSmokeError: LocalizedError {
    case configuration(String?)
    case generation(String?)

    var errorDescription: String? {
        switch self {
        case .configuration(let detail): return detail ?? "Runtime 未完成 M3 配置。"
        case .generation(let detail): return detail ?? "Runtime 未返回可见流式文本。"
        }
    }
}
