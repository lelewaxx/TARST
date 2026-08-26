import Darwin
import Foundation
import TARSTCore

private enum Stage {
    case synthesizingPrompt
    case recognizingPrompt
    case waitingForAgent
    case synthesizingResponse
}

private let voice = VolcengineTTSClient()
private let asr = VolcengineASRClient()
private let agent = AgentRuntimeClient()
private var stage = Stage.synthesizingPrompt
private var voiceCredentials: VolcengineVoiceCredentials?
private var promptPCM = Data()
private var promptSamples: [Int16] = []
private var promptPartialCount = 0
private var agentConfigured = false
private var pendingTranscript: String?
private var chunker = ChineseSentenceChunker()
private var submittedAt: Date?
private var userAudioEndedAt: Date?
private var asrFinishAt: Date?
private var asrFinalAt: Date?
private var agentFirstTextAt: Date?
private var phraseReadyAt: Date?
private var responseTTSRequestedAt: Date?
private var reported = false
private let endpointTailMilliseconds = 650
private let provider = CommandLine.arguments.dropFirst().first ?? "minimax_m2_her"
private let timeout = DispatchSource.makeTimerSource(queue: .main)

private func milliseconds(_ end: Date?, since start: Date?) -> Int? {
    guard let end, let start else { return nil }
    return Int(end.timeIntervalSince(start) * 1_000)
}

private func fail(_ error: Error) -> Never {
    guard !reported else { exit(1) }
    reported = true
    timeout.cancel()
    voice.cancel()
    asr.stop()
    agent.stop()
    fputs("End-to-end latency smoke test failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}

private func succeed(firstAudioAt: Date) -> Never {
    guard !reported else { exit(1) }
    reported = true
    timeout.cancel()
    voice.cancel()
    asr.stop()
    agent.stop()

    let vadTail = milliseconds(asrFinishAt, since: userAudioEndedAt) ?? endpointTailMilliseconds
    let asrFinalize = milliseconds(asrFinalAt, since: asrFinishAt) ?? -1
    let agentFirstText = milliseconds(agentFirstTextAt, since: submittedAt) ?? -1
    let phraseReady = milliseconds(phraseReadyAt, since: submittedAt) ?? -1
    let ttsFirstAudio = milliseconds(firstAudioAt, since: responseTTSRequestedAt) ?? -1
    let endToAudio = milliseconds(firstAudioAt, since: userAudioEndedAt) ?? -1
    print(
        "End-to-end latency smoke test passed [\(provider)] " +
        "(VAD tail \(vadTail) ms, ASR final \(asrFinalize) ms, " +
        "agent first text \(agentFirstText) ms, phrase ready \(phraseReady) ms, " +
        "TTS first audio \(ttsFirstAudio) ms, user end→first audio \(endToAudio) ms, " +
        "ASR partials \(promptPartialCount))."
    )
    exit(0)
}

private func downsample24kTo16k(_ data: Data) -> [Int16] {
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

private func startRealtimeASR() {
    guard let voiceCredentials else {
        fail(VolcengineASRError.invalidCredentials)
    }
    promptSamples = downsample24kTo16k(promptPCM)
    guard !promptSamples.isEmpty else { fail(VolcengineASRError.invalidResponse) }
    stage = .recognizingPrompt
    do {
        try asr.start(credentials: voiceCredentials)
    } catch {
        fail(error)
    }

    let chunks = stride(from: 0, to: promptSamples.count, by: 1_280).map {
        Array(promptSamples[$0..<min($0 + 1_280, promptSamples.count)])
    }
    for (index, chunk) in chunks.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.08) {
            guard stage == .recognizingPrompt else { return }
            asr.send(pcm: chunk)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(chunks.count) * 0.08) {
        guard stage == .recognizingPrompt else { return }
        userAudioEndedAt = Date()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Double(endpointTailMilliseconds) / 1_000
        ) {
            guard stage == .recognizingPrompt else { return }
            asrFinishAt = Date()
            asr.finish()
        }
    }
}

private func submitIfReady() {
    guard agentConfigured, let transcript = pendingTranscript else { return }
    pendingTranscript = nil
    stage = .waitingForAgent
    submittedAt = Date()
    do {
        try agent.submit(
            text: transcript,
            sessionID: UUID(),
            turnID: UUID(),
            generationID: UUID()
        )
    } catch {
        fail(error)
    }
}

private func synthesizeFirstPhrase(_ phrase: String) {
    guard stage == .waitingForAgent, let voiceCredentials else { return }
    stage = .synthesizingResponse
    phraseReadyAt = Date()
    responseTTSRequestedAt = Date()
    do {
        try voice.synthesize(phrase, credentials: voiceCredentials)
    } catch {
        fail(error)
    }
}

voice.onEvent = { event in
    switch event {
    case .ready:
        break
    case .audio(let data):
        switch stage {
        case .synthesizingPrompt:
            promptPCM.append(data)
        case .synthesizingResponse:
            succeed(firstAudioAt: Date())
        default:
            break
        }
    case .finished:
        if stage == .synthesizingPrompt { startRealtimeASR() }
    case .failure(let error):
        fail(error)
    }
}

asr.onEvent = { event in
    switch event {
    case .partial:
        promptPartialCount += 1
    case .final(let text):
        asrFinalAt = Date()
        pendingTranscript = text
        submitIfReady()
    case .failure(let error):
        fail(error)
    }
}

agent.onEvent = { event in
    switch event {
    case .configured(let configuredProvider) where configuredProvider == provider:
        agentConfigured = true
        submitIfReady()
    case .textDelta(_, _, _, let text):
        agentFirstTextAt = agentFirstTextAt ?? Date()
        if let phrase = chunker.append(text).first { synthesizeFirstPhrase(phrase) }
    case .completed:
        if stage == .waitingForAgent, let phrase = chunker.finish().first {
            synthesizeFirstPhrase(phrase)
        }
    case .failed(let code, let message):
        fail(NSError(
            domain: "TARST.EndToEndLatency.Agent",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(code): \(message)"]
        ))
    default:
        break
    }
}

timeout.schedule(deadline: .now() + 60)
timeout.setEventHandler {
    fail(NSError(
        domain: "TARST.EndToEndLatency",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "端到端延迟测试超时。"]
    ))
}
timeout.resume()

DispatchQueue.global().async {
    do {
        guard let credentials = try VolcengineCredentialsStore().load(allowInteraction: false),
              credentials.isComplete else {
            throw VolcengineASRError.invalidCredentials
        }
        DispatchQueue.main.async {
            voiceCredentials = credentials
            do {
                try agent.startUsingStoredCredentials(provider: provider)
                try voice.synthesize(
                    "请用一句简短的中文介绍你自己。",
                    credentials: credentials
                )
            } catch {
                fail(error)
            }
        }
    } catch {
        DispatchQueue.main.async { fail(error) }
    }
}

dispatchMain()
