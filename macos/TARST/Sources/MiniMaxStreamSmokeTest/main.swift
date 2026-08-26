import Darwin
import Foundation
import TARSTCore

@main
enum MiniMaxStreamSmokeTest {
    static func main() async {
        do {
            guard let credentials = try MiniMaxCredentialsStore().load(), credentials.isComplete else {
                throw StreamSmokeError.missingCredentials
            }
            var request = URLRequest(url: URL(string: "https://api.minimaxi.com/v1/text/chatcompletion_v2")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(credentials.normalized.apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30
            request.httpBody = try JSONEncoder().encode(StreamRequest(
                model: "MiniMax-M3",
                messages: [
                    StreamMessage(role: "system", name: "TARST", content: "You are a concise connectivity test."),
                    StreamMessage(role: "user", name: "user", content: "Reply with TARST M3 READY only.")
                ],
                // M3 can spend its early output budget on reasoning before it emits
                // visible text, so a minimal smoke test needs room for both.
                maxCompletionTokens: 256,
                stream: true
            ))

            let startedAt = Date()
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw StreamSmokeError.invalidHTTP
            }
            var firstTextAt: Date?
            var textDeltaCount = 0
            var dataLineCount = 0
            var firstPayloadKeys: [String] = []
            var firstDeltaKeys: [String] = []
            var choiceKeys: Set<String> = []
            var messageKeys: Set<String> = []
            for try await line in bytes.lines where line.hasPrefix("data:") {
                dataLineCount += 1
                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if firstPayloadKeys.isEmpty { firstPayloadKeys = object.keys.sorted() }
                if let code = ((object["base_resp"] as? [String: Any])?["status_code"] as? NSNumber)?.intValue, code != 0 {
                    throw StreamSmokeError.providerStatus(code)
                }
                let choice = (object["choices"] as? [[String: Any]])?.first
                choiceKeys.formUnion(choice.map { Array($0.keys) } ?? [])
                let deltaObject = choice?["delta"] as? [String: Any]
                let messageObject = choice?["message"] as? [String: Any]
                messageKeys.formUnion(messageObject.map { Array($0.keys) } ?? [])
                if firstDeltaKeys.isEmpty { firstDeltaKeys = deltaObject?.keys.sorted() ?? [] }
                let delta = (deltaObject?["content"] as? String) ?? (messageObject?["content"] as? String) ?? ""
                if !delta.isEmpty {
                    textDeltaCount += 1
                    firstTextAt = firstTextAt ?? Date()
                }
            }
            guard textDeltaCount > 0, let firstTextAt else {
                throw StreamSmokeError.noText(
                    dataLines: dataLineCount,
                    payloadKeys: firstPayloadKeys,
                    deltaKeys: firstDeltaKeys,
                    choiceKeys: choiceKeys.sorted(),
                    messageKeys: messageKeys.sorted()
                )
            }
            let firstTextMilliseconds = Int(firstTextAt.timeIntervalSince(startedAt) * 1_000)
            print("MiniMax M3 stream smoke test passed (HTTP 200, first text \(firstTextMilliseconds) ms, \(textDeltaCount) text deltas).")
        } catch {
            fputs("MiniMax M3 stream smoke test failed: \(safeDescription(for: error))\n", stderr)
            exit(1)
        }
    }

    private static func safeDescription(for error: Error) -> String {
        (error as? StreamSmokeError)?.localizedDescription ?? "无法完成流式请求。"
    }
}

private struct StreamRequest: Encodable {
    let model: String
    let messages: [StreamMessage]
    let maxCompletionTokens: Int
    let stream: Bool
    enum CodingKeys: String, CodingKey { case model, messages, stream; case maxCompletionTokens = "max_completion_tokens" }
}

private struct StreamMessage: Encodable { let role: String; let name: String; let content: String }

private enum StreamSmokeError: LocalizedError {
    case missingCredentials, invalidHTTP, providerStatus(Int)
    case noText(dataLines: Int, payloadKeys: [String], deltaKeys: [String], choiceKeys: [String], messageKeys: [String])
    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "未在 Keychain 找到 MiniMax API Key。"
        case .invalidHTTP: return "模型服务未返回 HTTP 2xx。"
        case .providerStatus(let code): return "模型服务返回业务错误 \(code)。"
        case .noText(let dataLines, let payloadKeys, let deltaKeys, let choiceKeys, let messageKeys):
            return "流式响应未包含可见文本（data lines: \(dataLines), payload fields: \(payloadKeys.joined(separator: ",")), choice fields: \(choiceKeys.joined(separator: ",")), delta fields: \(deltaKeys.joined(separator: ",")), message fields: \(messageKeys.joined(separator: ","))）。"
        }
    }
}
