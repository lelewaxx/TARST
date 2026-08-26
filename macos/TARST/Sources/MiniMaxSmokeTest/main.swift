import Darwin
import Foundation
import TARSTCore

@main
enum MiniMaxSmokeTest {
    static func main() async {
        do {
            guard let credentials = try MiniMaxCredentialsStore().load(), credentials.isComplete else {
                throw SmokeTestError.missingCredentials
            }

            var request = URLRequest(url: URL(string: "https://api.minimaxi.com/v1/text/chatcompletion_v2")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(credentials.normalized.apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 20
            request.httpBody = try JSONEncoder().encode(RequestBody(
                model: "MiniMax-M3",
                messages: [
                    Message(role: "system", name: "TARST", content: "You are a concise connectivity test."),
                    Message(role: "user", name: "user", content: "Reply with TARST M3 READY only.")
                ],
                maxCompletionTokens: 32
            ))

            let startedAt = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SmokeTestError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw SmokeTestError.httpStatus(http.statusCode)
            }
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SmokeTestError.unexpectedPayload(keys: [], serviceStatus: nil)
            }
            let serviceStatus = ((payload["base_resp"] as? [String: Any])?["status_code"] as? NSNumber)?.intValue
            guard let choices = payload["choices"] as? [[String: Any]],
                  choices.first?["message"] as? [String: Any] != nil else {
                throw SmokeTestError.unexpectedPayload(keys: payload.keys.sorted(), serviceStatus: serviceStatus)
            }

            let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            print("MiniMax M3 smoke test passed (HTTP \(http.statusCode), \(milliseconds) ms, \(data.count) response bytes).")
        } catch {
            fputs("MiniMax M3 smoke test failed: \(safeDescription(for: error))\n", stderr)
            exit(1)
        }
    }

    private static func safeDescription(for error: Error) -> String {
        switch error {
        case let value as SmokeTestError: value.localizedDescription
        case is URLError: "网络请求失败。"
        default: "无法完成请求。"
        }
    }
}

private struct RequestBody: Encodable {
    let model: String
    let messages: [Message]
    let maxCompletionTokens: Int

    enum CodingKeys: String, CodingKey {
        case model, messages
        case maxCompletionTokens = "max_completion_tokens"
    }
}

private struct Message: Encodable {
    let role: String
    let name: String
    let content: String
}

private enum SmokeTestError: LocalizedError {
    case missingCredentials
    case invalidResponse
    case httpStatus(Int)
    case unexpectedPayload(keys: [String], serviceStatus: Int?)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "未在 Keychain 找到 MiniMax API Key。"
        case .invalidResponse: return "模型服务返回了无效响应。"
        case .httpStatus(let code): return "模型服务返回 HTTP \(code)。"
        case .unexpectedPayload(let keys, let serviceStatus):
            let status = serviceStatus.map { ", service status \($0)" } ?? ""
            return "模型服务返回了不符合预期的结果（fields: \(keys.joined(separator: ","))\(status)）。"
        }
    }
}
