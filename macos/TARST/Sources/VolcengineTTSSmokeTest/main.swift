import Foundation
import TARSTCore

let client = VolcengineTTSClient()
var chunks = 0
var bytes = 0
var completedSessions = 0
var sessionRequestedAt: Date?
var currentSessionHasAudio = false
var firstAudioMilliseconds: [Int] = []
var reported = false
let timeout = DispatchSource.makeTimerSource(queue: .main)

func report(_ error: Error? = nil) -> Never {
    guard !reported else { exit(1) }
    reported = true
    timeout.cancel()
    if let error {
        fputs("Volcengine V3 TTS smoke test failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    guard chunks > 0, bytes > 0 else {
        fputs("Volcengine V3 TTS smoke test failed: no PCM audio received\n", stderr)
        exit(1)
    }
    guard completedSessions == 2 else {
        fputs("Volcengine V3 TTS smoke test failed: persistent connection did not finish two sessions\n", stderr)
        exit(1)
    }
    print("Volcengine V3 persistent TTS smoke test passed (2 sessions, first audio \(firstAudioMilliseconds) ms, \(chunks) PCM chunks, \(bytes) bytes).")
    exit(0)
}

client.onEvent = { event in
    switch event {
    case .ready: break
    case .audio(let data):
        if !currentSessionHasAudio, let sessionRequestedAt {
            currentSessionHasAudio = true
            firstAudioMilliseconds.append(Int(Date().timeIntervalSince(sessionRequestedAt) * 1_000))
        }
        chunks += 1
        bytes += data.count
    case .finished:
        completedSessions += 1
        if completedSessions == 1 {
            do {
                guard let credentials = try VolcengineCredentialsStore().load(allowInteraction: false) else {
                    throw VolcengineASRError.invalidCredentials
                }
                currentSessionHasAudio = false
                sessionRequestedAt = Date()
                try client.synthesize("这是同一条连接上的第二段语音。", credentials: credentials)
            } catch {
                report(error)
            }
        } else {
            report()
        }
    case .failure(let error): report(error)
    }
}
timeout.schedule(deadline: .now() + 30)
timeout.setEventHandler {
    report(NSError(
        domain: "TARST.TTSSmoke",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "火山 V3 TTS 验证超时（Keychain 未返回或服务未完成）。"]
    ))
}
timeout.resume()
// A Keychain item whose ACL does not include this CLI can block inside
// SecItemCopyMatching. Perform that lookup away from main so the deadline
// remains enforceable and this helper never leaves an orphaned process.
DispatchQueue.global().async {
    do {
        guard let credentials = try VolcengineCredentialsStore().load(allowInteraction: false), credentials.isTTSComplete else {
            throw VolcengineASRError.invalidCredentials
        }
        DispatchQueue.main.async {
            do {
                sessionRequestedAt = Date()
                try client.synthesize("你好，我是 TARST。现在我会完整地完成这段较长的语音合成，并在所有 PCM 数据传输结束后再报告成功。", credentials: credentials)
            } catch {
                report(error)
            }
        }
    } catch {
        DispatchQueue.main.async { report(error) }
    }
}
dispatchMain()
