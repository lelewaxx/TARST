import Foundation
import TARSTCore

let tts = VolcengineTTSClient()
let asr = VolcengineASRClient()
var pcm24k = Data()
var partialCount = 0
var reported = false
let timeout = DispatchSource.makeTimerSource(queue: .main)

func finish(_ error: Error? = nil, finalLength: Int = 0) -> Never {
    guard !reported else { exit(1) }
    reported = true
    timeout.cancel()
    tts.cancel()
    asr.stop()
    if let error {
        fputs("Volcengine ASR round-trip smoke test failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    guard finalLength > 0 else {
        fputs("Volcengine ASR round-trip smoke test failed: no final transcript\n", stderr)
        exit(1)
    }
    print("Volcengine ASR round-trip smoke test passed (\(partialCount) partials, final length \(finalLength)).")
    exit(0)
}

func downsample24kTo16k(_ data: Data) -> [Int16] {
    let input: [Int16] = data.withUnsafeBytes { raw in Array(raw.bindMemory(to: Int16.self)) }
    guard input.count >= 2 else { return input }
    let outputCount = input.count * 2 / 3
    return (0..<outputCount).map { index in
        let position = Double(index) * 1.5
        let lower = min(Int(position), input.count - 1)
        let upper = min(lower + 1, input.count - 1)
        let fraction = position - Double(lower)
        let value = Double(input[lower]) * (1 - fraction) + Double(input[upper]) * fraction
        return Int16(max(Double(Int16.min), min(Double(Int16.max), value)))
    }
}

func startASR(credentials: VolcengineVoiceCredentials) {
    do {
        let samples = downsample24kTo16k(pcm24k)
        guard !samples.isEmpty else { finish(VolcengineASRError.invalidResponse) }
        try asr.start(credentials: credentials)
        // Intentionally enqueue all PCM and finish immediately. This reproduces
        // the barge-in boundary where the utterance can end before WebSocket open.
        for offset in stride(from: 0, to: samples.count, by: 1_280) {
            asr.send(pcm: Array(samples[offset..<min(offset + 1_280, samples.count)]))
        }
        asr.finish()
    } catch {
        finish(error)
    }
}

DispatchQueue.global().async {
    do {
        guard let credentials = try VolcengineCredentialsStore().load(allowInteraction: false),
              credentials.isComplete else { throw VolcengineASRError.invalidCredentials }
        DispatchQueue.main.async {
            asr.onEvent = { event in
                switch event {
                case .partial: partialCount += 1
                case .final(let text): finish(finalLength: text.count)
                case .failure(let error): finish(error)
                }
            }
            tts.onEvent = { event in
                switch event {
                case .ready: break
                case .audio(let data): pcm24k.append(data)
                case .finished: startASR(credentials: credentials)
                case .failure(let error): finish(error)
                }
            }
            do {
                try tts.synthesize("你好，我是 TARST。现在进行连续对话语音识别测试。", credentials: credentials)
            } catch {
                finish(error)
            }
        }
    } catch {
        DispatchQueue.main.async { finish(error) }
    }
}

timeout.schedule(deadline: .now() + 45)
timeout.setEventHandler {
    finish(NSError(
        domain: "TARST.ASRRoundTripSmoke",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "火山 ASR 回环测试超时。"]
    ))
}
timeout.resume()
dispatchMain()
