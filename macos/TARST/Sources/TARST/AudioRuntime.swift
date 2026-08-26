import AVFoundation
import Foundation

private struct TTSQueueItem {
    let text: String
    let attempt: Int
}

public final class AudioRuntime {
    public enum Event {
        case agentConfigured
        case wakeWord(Int)
        case speechStarted
        case turnEnded
        case speechDuringResponse
        case waitingTimedOut
        case turnFailed
        case asrPartial(String)
        case asrFinal(String)
        case agentTextDelta(String)
        case agentCompleted
        case error(Error)
    }

    public var onEvent: ((Event) -> Void)?
    private let audioEngine = AVAudioEngine()
    private let processingQueue = DispatchQueue(label: "com.tarst.audio-processing")
    private let ringBuffer = PCM16RingBuffer()
    private let diagnostics = DiagnosticsRecorder()
    private var detector: LocalVoiceDetector?
    private var asr: VolcengineASRClient?
    private var bargeInProbe: VolcengineASRClient?
    private var bargeInProbeTracker = InterruptionProbeTracker()
    private var lastBargeInDiagnostic: (length: Int, classification: InterruptionTextClassification)?
    private var bargeInProbeStartedAt: TimeInterval?
    private var bargeInCandidateStartedAt: TimeInterval?
    private var isPlaybackPausedForBargeIn = false
    private var bargeInPauseGeneration = 0
    private var bargeInPlaybackPausedAt: TimeInterval?
    /// Loaded once when the user explicitly starts listening, then held only for
    /// this listening session. Never query Keychain on the real-time audio path.
    private var asrCredentials: VolcengineVoiceCredentials?
    private var miniMaxCredentials: MiniMaxCredentials?
    private var agent: AgentRuntimeClient?
    private var agentConfigured = false
    private var agentSessionID = UUID()
    private var activeGenerationID: UUID?
    private var cancelledGenerationIDs: Set<UUID> = []
    private var pendingAgentInput: String?
    private let pcmPlayer = PCMPlayer()
    private var tts: VolcengineTTSClient?
    private var ttsSessionActive = false
    private var activeTTSItem: TTSQueueItem?
    private var ttsQueue: [TTSQueueItem] = []
    private var sentenceChunker = ChineseSentenceChunker()
    private var agentGenerationFinished = false
    private var agentResponseText = ""
    private var agentStartedAt: TimeInterval?
    private var firstAgentTextRecorded = false
    private var firstTTSRequestedAt: TimeInterval?
    private var firstTTSAudioRecorded = false
    private var firstPlaybackRecorded = false
    private var asrFinishRequestedAt: TimeInterval?
    private var lastUserVoiceAt: TimeInterval?
    private var latestASRPartial = ""
    private var accumulated: [Int16] = []
    private var lastIgnoredVoiceDiagnosticAt: TimeInterval = 0
    private let session = SessionController()
    private var isRunning = false
    private var isTapInstalled = false

    public init() {}

    public var isDiagnosticsRecording: Bool { diagnostics.isRecording }

    @discardableResult
    public func startDiagnostics() throws -> URL {
        let device = AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"
        return try diagnostics.start(metadata: [
            "schema_version": 1,
            "contains_audio": false,
            "input_device": device,
            "sample_rate": 16_000,
            "frame_samples": 1_280,
            "wake_threshold": 0.55,
            "vad_threshold": 0.50,
            "models": ["TARST", "Hey-TARST"],
        ])
    }

    public func stopDiagnostics() { diagnostics.stop() }

    public func recordDiagnosticLabel(_ name: String, keyword: String? = nil) {
        var fields: [String: Any] = [:]
        if let keyword { fields["keyword"] = keyword }
        diagnostics.recordEvent("label", fields: fields.merging(["name": name]) { _, new in new })
    }

    public func start() throws {
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw NSError(
                domain: "TARST.AudioRuntime",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "未检测到麦克风。请连接 AirPods、USB 麦克风或其他音频输入设备后重试。"]
            )
        }

        if asrCredentials == nil {
            guard let credentials = try VolcengineCredentialsStore().load(), credentials.isComplete else {
                throw VolcengineASRError.invalidCredentials
            }
            asrCredentials = credentials.normalized
        }
        if miniMaxCredentials == nil {
            guard let credentials = try MiniMaxCredentialsStore().load(), credentials.isComplete else {
                throw AgentRuntimeClientError.missingCredentials
            }
            miniMaxCredentials = credentials.normalized
        }
        try startAgent(credentials: miniMaxCredentials!)
        prepareTTSIfNeeded(credentials: asrCredentials!)

        let localDetector = try LocalVoiceDetector()
        localDetector.onEvent = { [weak self] event in
            self?.processingQueue.async { self?.consume(event) }
        }
        detector = localDetector
        accumulated.removeAll(keepingCapacity: true)
        accumulated.reserveCapacity(1280 * 2)
        do {
            try installTap(sampleRate: 16_000)
            audioEngine.prepare()
            try audioEngine.start()
            isRunning = true
            session.resume()
            diagnostics.recordEvent("listening_started")
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        if isRunning { diagnostics.recordEvent("listening_stopped") }
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        audioEngine.stop()
        detector?.stop()
        detector = nil
        asr?.stop()
        asr = nil
        bargeInProbe?.stop()
        bargeInProbe = nil
        bargeInProbeTracker.reset()
        lastBargeInDiagnostic = nil
        bargeInProbeStartedAt = nil
        bargeInCandidateStartedAt = nil
        isPlaybackPausedForBargeIn = false
        bargeInPauseGeneration += 1
        bargeInPlaybackPausedAt = nil
        agent?.stop()
        agent = nil
        agentConfigured = false
        activeGenerationID = nil
        cancelledGenerationIDs.removeAll()
        pendingAgentInput = nil
        cancelTTS()
        isRunning = false
        accumulated.removeAll(keepingCapacity: false)
        ringBuffer.clear()
        session.pause()
    }

    public func beginResponse() { processingQueue.async { self.session.beginResponse() } }
    /// Settings windows call this after saving or deleting credentials. Normal
    /// stop/start cycles deliberately retain the decoded values in memory so the
    /// Keychain does not ask for authorization every time listening is toggled.
    public func invalidateCredentialCache() {
        asrCredentials = nil
        miniMaxCredentials = nil
    }

    /// Developer-only acoustic check used by the signed app smoke mode. It sends
    /// a known phrase through the normal TTS/PCM path without creating a model
    /// turn, allowing the captured VAD to verify ReSpeaker's hardware AEC.
    public func speakDiagnosticPhrase(_ text: String) {
        processingQueue.async {
            guard self.isRunning else { return }
            self.session.beginResponse()
            self.agentGenerationFinished = true
            self.agentResponseText = text
            self.enqueueTTS(text)
        }
    }

    private func installTap(sampleRate: Double) throws {
        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let detectorFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: detectorFormat) else {
            throw NSError(
                domain: "TARST.AudioRuntime",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法初始化麦克风音频格式转换器。"]
            )
        }

        if isTapInstalled {
            input.removeTap(onBus: 0)
            isTapInstalled = false
        }
        // A tap must use the input node's native hardware format. Requiring 16 kHz
        // here causes Core Audio to raise an Objective-C exception on common 48 kHz
        // devices. Convert to the detector's mono 16 kHz format in memory instead.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            let ratio = detectorFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: detectorFormat, frameCapacity: capacity) else { return }

            var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                guard !suppliedInput else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, conversionError == nil,
                  let channel = converted.floatChannelData?[0] else { return }

            let count = Int(converted.frameLength)
            var pcm = [Int16]()
            pcm.reserveCapacity(count)
            for sample in UnsafeBufferPointer(start: channel, count: count) {
                pcm.append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
            }
            self?.processingQueue.async { self?.consume(pcm) }
        }
        isTapInstalled = true
    }

    private func consume(_ pcm: [Int16]) {
        guard isRunning, detector != nil else { return }
        ringBuffer.append(pcm[...])
        asr?.send(pcm: pcm)
        bargeInProbe?.send(pcm: pcm)
        accumulated.append(contentsOf: pcm)
        while accumulated.count >= 1280 { // openWakeWord's recommended 80 ms frame at 16 kHz.
            let frame = accumulated.prefix(1280)
            accumulated.removeFirst(1280)
            do { try detector?.process(frame) } catch {
                emit(.error(error))
                stop()
                return
            }
        }
    }

    private func consume(_ event: LocalVoiceDetector.Event) {
        guard isRunning else { return }
        switch event {
        case .prediction(let keywordIndex, let wakeScores, let voiceProbability):
            diagnostics.recordFrame(
                wakeScores: wakeScores,
                voiceProbability: voiceProbability,
                keywordIndex: keywordIndex
            )
            evaluate(keywordIndex: keywordIndex, voiceProbability: voiceProbability)
        case .error(let message):
            emit(.error(LocalVoiceDetectorError.failedToStart(message)))
        }
    }

    private func evaluate(keywordIndex: Int?, voiceProbability: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        if asr != nil, voiceProbability >= 0.5 { lastUserVoiceAt = now }
        let isSpeaking = ttsSessionActive || !ttsQueue.isEmpty || !pcmPlayer.isDrained
        let permitsBargeIn = !isSpeaking
        let prefersFastEndpoint = Self.hasCompleteUtterancePunctuation(latestASRPartial)
        if isSpeaking, voiceProbability >= 0.5 {
            bargeInCandidateStartedAt = bargeInCandidateStartedAt ?? now
            startBargeInProbeIfNeeded()
        }
        let effect = session.process(
            keywordIndex: keywordIndex,
            voiceProbability: voiceProbability,
            at: now,
            permitsBargeIn: permitsBargeIn,
            prefersFastEndpoint: prefersFastEndpoint
        )
        if isSpeaking, !permitsBargeIn, voiceProbability >= 0.5,
           now - lastIgnoredVoiceDiagnosticAt >= 1 {
            lastIgnoredVoiceDiagnosticAt = now
            diagnostics.recordEvent("playback_voice_ignored")
        }
        switch effect {
        case .none: break
        case .wakeWordAccepted:
            diagnostics.recordEvent("wake_accepted", fields: ["keyword_index": keywordIndex ?? 0])
            emit(.wakeWord(keywordIndex ?? 0))
        case .speechStarted:
            diagnostics.recordEvent("speech_started")
            lastUserVoiceAt = now
            startASR()
            emit(.speechStarted)
        case .turnEnded:
            asrFinishRequestedAt = now
            var fields: [String: Any] = [:]
            if let lastUserVoiceAt {
                fields["vad_tail_ms"] = Int((now - lastUserVoiceAt) * 1_000)
            }
            fields["endpoint_mode"] = prefersFastEndpoint ? "punctuation" : "silence"
            diagnostics.recordEvent("turn_ended", fields: fields)
            asr?.finish()
            emit(.turnEnded)
        case .speechDuringResponse:
            diagnostics.recordEvent("speech_during_response")
            cancelAgentGeneration()
            // This voice activity is the beginning of the next turn, not only a
            // stop command. Start ASR immediately so a user can barge in without
            // repeating the wake word after TARST is interrupted.
            startASR(includePreRoll: true)
            emit(.speechDuringResponse)
        case .waitingTimedOut:
            diagnostics.recordEvent("waiting_timed_out")
            emit(.waitingTimedOut)
        }
    }

    private func startASR(includePreRoll: Bool = true) {
        do {
            guard let credentials = asrCredentials, credentials.isASRComplete else {
                throw VolcengineASRError.invalidCredentials
            }
            prepareTTSIfNeeded(credentials: credentials)
            let client = VolcengineASRClient()
            client.onEvent = { [weak self, weak client] event in
                guard let client else { return }
                self?.processingQueue.async { self?.consumeASR(event, from: client) }
            }
            try client.start(credentials: credentials)
            asr = client
            asrFinishRequestedAt = nil
            latestASRPartial = ""
            diagnostics.recordEvent("asr_started")
            // Detector callbacks arrive after the audio frame that caused them;
            // prepend a small in-memory tail so the first spoken syllable survives.
            if includePreRoll { client.send(pcm: ringBuffer.recent(seconds: 0.5)) }
        } catch { emit(.error(error)) }
    }

    private func startBargeInProbeIfNeeded() {
        guard bargeInProbe == nil, asr == nil,
              let credentials = asrCredentials, credentials.isASRComplete else { return }
        let client = VolcengineASRClient()
        client.onEvent = { [weak self, weak client] event in
            guard let client else { return }
            self?.processingQueue.async { self?.consumeBargeInProbe(event, from: client) }
        }
        do {
            try client.start(credentials: credentials)
            bargeInProbe = client
            bargeInProbeTracker.reset()
            lastBargeInDiagnostic = nil
            bargeInProbeStartedAt = ProcessInfo.processInfo.systemUptime
            client.send(pcm: ringBuffer.recent(seconds: 0.5))
            diagnostics.recordEvent("barge_in_probe_started")
        } catch {
            diagnostics.recordEvent("barge_in_probe_failed")
        }
    }

    private func consumeBargeInProbe(_ event: VolcengineASRClient.Event, from client: VolcengineASRClient) {
        guard isRunning, bargeInProbe === client else { return }
        switch event {
        case .partial(let text):
            let classification = bargeInProbeTracker.observe(
                candidate: text,
                spokenResponse: agentResponseText
            )
            let diagnostic = (text.count, classification)
            if lastBargeInDiagnostic?.length != diagnostic.0 ||
                lastBargeInDiagnostic?.classification != diagnostic.1 {
                lastBargeInDiagnostic = diagnostic
                diagnostics.recordEvent("barge_in_probe_partial", fields: [
                    "candidate_length": text.count,
                    "classification": String(describing: classification),
                ])
            }
            if classification == .user { confirmBargeIn() }
            else if classification == .suspectedUser { pausePlaybackForBargeInIfNeeded() }
            else if classification == .echo {
                resumePlaybackAfterFalseBargeInIfNeeded(reason: "echo")
            }
            if classification == .echo,
                    text.count >= 24,
                    let startedAt = bargeInProbeStartedAt,
                    ProcessInfo.processInfo.systemUptime - startedAt >= 2.5 {
                // A long cumulative echo prefix delays recognition of a later
                // user suffix. Rotate the probe while preserving 0.5 s pre-roll
                // so the active transcript window stays short.
                client.stop()
                bargeInProbe = nil
                bargeInProbeTracker.reset()
                lastBargeInDiagnostic = nil
                bargeInProbeStartedAt = nil
                diagnostics.recordEvent("barge_in_probe_rotated")
                startBargeInProbeIfNeeded()
            }
        case .final(let text):
            bargeInProbe = nil
            let classification = bargeInProbeTracker.observe(
                candidate: text,
                spokenResponse: agentResponseText
            )
            diagnostics.recordEvent("barge_in_probe_final", fields: [
                "candidate_length": text.count,
                "classification": String(describing: classification),
            ])
            if classification == .user { confirmBargeIn(finalText: text) }
            else {
                resumePlaybackAfterFalseBargeInIfNeeded(reason: "final")
                bargeInCandidateStartedAt = nil
            }
        case .failure:
            bargeInProbe = nil
            resumePlaybackAfterFalseBargeInIfNeeded(reason: "failure")
            bargeInCandidateStartedAt = nil
            diagnostics.recordEvent("barge_in_probe_failed")
        }
    }

    private func confirmBargeIn(finalText: String? = nil) {
        bargeInProbe?.stop()
        bargeInProbe = nil
        bargeInProbeTracker.reset()
        lastBargeInDiagnostic = nil
        bargeInProbeStartedAt = nil
        var fields: [String: Any] = [:]
        if let bargeInCandidateStartedAt {
            fields["confirmation_ms"] = Int(
                (ProcessInfo.processInfo.systemUptime - bargeInCandidateStartedAt) * 1_000
            )
        }
        if let bargeInPlaybackPausedAt {
            fields["pause_to_confirmation_ms"] = Int(
                (ProcessInfo.processInfo.systemUptime - bargeInPlaybackPausedAt) * 1_000
            )
        }
        self.bargeInCandidateStartedAt = nil
        bargeInPlaybackPausedAt = nil
        isPlaybackPausedForBargeIn = false
        bargeInPauseGeneration += 1
        diagnostics.recordEvent("speech_during_response", fields: fields)
        cancelAgentGeneration()
        emit(.speechDuringResponse)
        if let finalText, !finalText.isEmpty {
            session.beginResponse()
            emit(.asrFinal(finalText))
            submitAgent(finalText)
        } else {
            let now = ProcessInfo.processInfo.systemUptime
            session.acceptBargeIn(at: now)
            lastUserVoiceAt = now
            startASR(includePreRoll: true)
        }
    }

    private func pausePlaybackForBargeInIfNeeded() {
        guard !isPlaybackPausedForBargeIn, !pcmPlayer.isDrained else { return }
        isPlaybackPausedForBargeIn = true
        bargeInPauseGeneration += 1
        let generation = bargeInPauseGeneration
        let now = ProcessInfo.processInfo.systemUptime
        bargeInPlaybackPausedAt = now
        pcmPlayer.pause()
        var fields: [String: Any] = [:]
        if let bargeInCandidateStartedAt {
            fields["candidate_to_pause_ms"] = Int((now - bargeInCandidateStartedAt) * 1_000)
        }
        diagnostics.recordEvent("barge_in_playback_paused", fields: fields)
        processingQueue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self,
                  self.isPlaybackPausedForBargeIn,
                  self.bargeInPauseGeneration == generation else { return }
            self.resumePlaybackAfterFalseBargeInIfNeeded(reason: "timeout")
        }
    }

    private func resumePlaybackAfterFalseBargeInIfNeeded(reason: String) {
        guard isPlaybackPausedForBargeIn else { return }
        isPlaybackPausedForBargeIn = false
        bargeInPauseGeneration += 1
        var fields: [String: Any] = ["reason": reason]
        if let bargeInPlaybackPausedAt {
            fields["paused_ms"] = Int(
                (ProcessInfo.processInfo.systemUptime - bargeInPlaybackPausedAt) * 1_000
            )
        }
        bargeInPlaybackPausedAt = nil
        pcmPlayer.resume()
        diagnostics.recordEvent("barge_in_playback_resumed", fields: fields)
    }

    private func consumeASR(_ event: VolcengineASRClient.Event, from client: VolcengineASRClient) {
        // A previous turn may close asynchronously after a barge-in. It must
        // never submit another model turn or turn the new turn into an error.
        guard isRunning, asr === client else { return }
        switch event {
        case .partial(let text):
            latestASRPartial = text
            emit(.asrPartial(text))
        case .final(let text):
            var fields: [String: Any] = [:]
            if let asrFinishRequestedAt {
                fields["finalize_ms"] = Int((ProcessInfo.processInfo.systemUptime - asrFinishRequestedAt) * 1_000)
            }
            diagnostics.recordEvent("asr_final", fields: fields)
            asr = nil
            asrFinishRequestedAt = nil
            lastUserVoiceAt = nil
            latestASRPartial = ""
            emit(.asrFinal(text))
            submitAgent(text)
        case .failure(let error):
            asr = nil
            // A transient WebSocket failure belongs to this utterance, not the
            // whole always-on microphone session. Return to the companion
            // follow-up window so the user can repeat the sentence directly.
            let nsError = error as NSError
            diagnostics.recordEvent("asr_turn_failed", fields: [
                "domain": nsError.domain,
                "code": nsError.code,
            ])
            asrFinishRequestedAt = nil
            lastUserVoiceAt = nil
            latestASRPartial = ""
            session.responseFinished()
            emit(.turnFailed)
        }
    }

    private func startAgent(credentials: MiniMaxCredentials) throws {
        let client = AgentRuntimeClient()
        client.onEvent = { [weak self, weak client] event in
            guard let client else { return }
            self?.processingQueue.async { self?.consumeAgent(event, from: client) }
        }
        agentConfigured = false
        // Publish the client before starting its very fast local subprocess.
        // runtime.configured can arrive while the microphone is still being
        // installed; assigning afterward creates a race where readiness is lost.
        agent = client
        do {
            try client.start(credentials: credentials)
        } catch {
            agent = nil
            throw error
        }
        agentSessionID = UUID()
        pcmPlayer.onQueueDrained = { [weak self] in
            self?.processingQueue.async {
                self?.diagnostics.recordEvent("tts_playback_drained")
                self?.finishResponseIfDrained()
            }
        }
    }

    private func submitAgent(_ text: String) {
        guard !text.isEmpty else { return }
        guard activeGenerationID == nil, pendingAgentInput == nil else { return }
        guard agentConfigured else {
            pendingAgentInput = text
            return
        }
        let turnID = UUID()
        let generationID = UUID()
        do {
            agentResponseText = ""
            activeGenerationID = generationID
            agentStartedAt = ProcessInfo.processInfo.systemUptime
            firstAgentTextRecorded = false
            firstTTSRequestedAt = nil
            firstTTSAudioRecorded = false
            firstPlaybackRecorded = false
            try agent?.submit(text: text, sessionID: agentSessionID, turnID: turnID, generationID: generationID)
            agentGenerationFinished = false
            diagnostics.recordEvent("agent_started")
        } catch { emit(.error(error)) }
    }

    private func cancelAgentGeneration() {
        cancelTTS()
        guard let generationID = activeGenerationID else { return }
        cancelledGenerationIDs.insert(generationID)
        do { try agent?.cancel(generationID: generationID) }
        catch {
            cancelledGenerationIDs.remove(generationID)
            emit(.error(error))
        }
        activeGenerationID = nil
        agentGenerationFinished = false
    }

    private func consumeAgent(_ event: AgentRuntimeClient.Event, from client: AgentRuntimeClient) {
        // Accept configuration readiness during AudioRuntime.start(), before
        // isRunning flips true. All events from a stopped/replaced subprocess
        // are rejected by identity so stale callbacks cannot revive it.
        guard agent === client else { return }
        switch event {
        case .configured(let provider):
            agentConfigured = true
            diagnostics.recordEvent("agent_configured", fields: ["provider": provider])
            emit(.agentConfigured)
            if let input = pendingAgentInput {
                pendingAgentInput = nil
                submitAgent(input)
            }
        case .textDelta(_, _, let generationID, let text):
            guard isRunning else { return }
            guard generationID == activeGenerationID else { return }
            if !text.isEmpty, !firstAgentTextRecorded {
                firstAgentTextRecorded = true
                var fields: [String: Any] = [:]
                if let agentStartedAt {
                    fields["latency_ms"] = Int((ProcessInfo.processInfo.systemUptime - agentStartedAt) * 1_000)
                }
                diagnostics.recordEvent("agent_first_text", fields: fields)
            }
            agentResponseText += text
            for sentence in sentenceChunker.append(text) { enqueueTTS(sentence) }
            emit(.agentTextDelta(text))
        case .streamDiagnostic(_, _, let generationID, let fields):
            guard isRunning else { return }
            guard generationID == activeGenerationID else { return }
            diagnostics.recordEvent(
                "agent_stream_frame",
                fields: fields.mapValues(\.value)
            )
        case .completed(_, _, let generationID):
            guard isRunning else { return }
            guard generationID == activeGenerationID else { return }
            for sentence in sentenceChunker.finish() { enqueueTTS(sentence) }
            activeGenerationID = nil
            diagnostics.recordEvent("agent_completed")
            agentGenerationFinished = true
            finishResponseIfDrained()
        case .cancelled(_, _, let generationID):
            guard isRunning else { return }
            // Cancellation acknowledgements are asynchronous. A previous
            // generation may acknowledge after the user's barge-in has already
            // opened or submitted the next turn, so it must never mutate that
            // newer turn's state or emit agentCompleted.
            cancelledGenerationIDs.remove(generationID)
            if activeGenerationID == generationID {
                activeGenerationID = nil
                agentGenerationFinished = false
            }
        case .failed(_, let message):
            guard isRunning else { return }
            emit(.error(NSError(domain: "TARST.Agent", code: 1, userInfo: [NSLocalizedDescriptionKey: message])))
        case .ready, .textCompleted:
            break
        }
    }

    private func enqueueTTS(_ sentence: String) {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ttsQueue.append(TTSQueueItem(text: text, attempt: 0))
        startNextTTSIfNeeded()
    }

    private func prepareTTSIfNeeded(credentials: VolcengineVoiceCredentials) {
        guard tts == nil else { return }
        let client = VolcengineTTSClient()
        client.onEvent = { [weak self, weak client] event in
            guard let client else { return }
            self?.processingQueue.async { self?.consumeTTS(event, from: client) }
        }
        tts = client
        do {
            try client.prepare(credentials: credentials)
            diagnostics.recordEvent("tts_connection_preparing")
        } catch {
            tts = nil
        }
    }

    private func startNextTTSIfNeeded() {
        guard !ttsSessionActive, !ttsQueue.isEmpty, let credentials = asrCredentials else { return }
        prepareTTSIfNeeded(credentials: credentials)
        guard let client = tts else { return }
        let item = ttsQueue.removeFirst()
        activeTTSItem = item
        ttsSessionActive = true
        if firstTTSRequestedAt == nil { firstTTSRequestedAt = ProcessInfo.processInfo.systemUptime }
        diagnostics.recordEvent("tts_started", fields: ["queued_sentences": ttsQueue.count])
        do { try client.synthesize(item.text, credentials: credentials) }
        catch { handleTTSFailure(error, from: client) }
    }

    private func consumeTTS(_ event: VolcengineTTSClient.Event, from client: VolcengineTTSClient) {
        // Ignore completion/failure events belonging to a cancelled or already
        // replaced WebSocket. URLSession delivers those callbacks asynchronously.
        guard tts === client else { return }
        switch event {
        case .ready:
            diagnostics.recordEvent("tts_connection_ready")
        case .audio(let data):
            if !firstTTSAudioRecorded {
                firstTTSAudioRecorded = true
                var fields: [String: Any] = ["bytes": data.count]
                if let firstTTSRequestedAt {
                    fields["latency_ms"] = Int((ProcessInfo.processInfo.systemUptime - firstTTSRequestedAt) * 1_000)
                }
                diagnostics.recordEvent("tts_first_audio", fields: fields)
            }
            do {
                try pcmPlayer.play(data)
                if !firstPlaybackRecorded {
                    firstPlaybackRecorded = true
                    diagnostics.recordEvent("playback_started")
                }
            } catch { emit(.error(error)) }
        case .finished:
            diagnostics.recordEvent("tts_stream_finished")
            ttsSessionActive = false
            activeTTSItem = nil
            startNextTTSIfNeeded()
            finishResponseIfDrained()
        case .failure(let error):
            handleTTSFailure(error, from: client)
        }
    }

    private func handleTTSFailure(_ error: Error, from client: VolcengineTTSClient) {
        guard tts === client else { return }
        let failedItem = activeTTSItem
        client.cancel()
        tts = nil
        ttsSessionActive = false
        activeTTSItem = nil
        if let failedItem, failedItem.attempt < 1 {
            diagnostics.recordEvent("tts_reconnecting")
            ttsQueue.insert(TTSQueueItem(text: failedItem.text, attempt: failedItem.attempt + 1), at: 0)
            startNextTTSIfNeeded()
        } else {
            emit(.error(error))
        }
    }

    private func cancelTTS() {
        if ttsSessionActive || !ttsQueue.isEmpty || !pcmPlayer.isDrained {
            diagnostics.recordEvent("tts_cancelled")
        }
        tts?.cancel()
        tts = nil
        ttsSessionActive = false
        activeTTSItem = nil
        ttsQueue.removeAll(keepingCapacity: false)
        sentenceChunker = ChineseSentenceChunker()
        pcmPlayer.stop()
        isPlaybackPausedForBargeIn = false
        bargeInPauseGeneration += 1
        bargeInPlaybackPausedAt = nil
    }

    private func finishResponseIfDrained() {
        guard agentGenerationFinished, activeGenerationID == nil, !ttsSessionActive, ttsQueue.isEmpty, pcmPlayer.isDrained else { return }
        bargeInProbe?.stop()
        bargeInProbe = nil
        bargeInProbeTracker.reset()
        lastBargeInDiagnostic = nil
        bargeInProbeStartedAt = nil
        bargeInCandidateStartedAt = nil
        isPlaybackPausedForBargeIn = false
        bargeInPauseGeneration += 1
        bargeInPlaybackPausedAt = nil
        agentGenerationFinished = false
        session.responseFinished()
        emit(.agentCompleted)
    }

    private func emit(_ event: Event) {
        if case .error(let error) = event {
            let nsError = error as NSError
            diagnostics.recordEvent("runtime_error", fields: [
                "domain": nsError.domain,
                "code": nsError.code,
            ])
        }
        DispatchQueue.main.async { self.onEvent?(event) }
    }

    private static func hasCompleteUtterancePunctuation(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 4, let last = value.last else { return false }
        return "。！？!?".contains(last)
    }
}
