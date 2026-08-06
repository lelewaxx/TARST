import AVFoundation
import Foundation

public final class AudioRuntime {
    public enum Event {
        case wakeWord(Int)
        case speechStarted
        case turnEnded
        case speechDuringResponse
        case waitingTimedOut
        case error(Error)
    }

    public var onEvent: ((Event) -> Void)?
    private let audioEngine = AVAudioEngine()
    private let processingQueue = DispatchQueue(label: "com.tarst.audio-processing")
    private let policy = SessionPolicy()
    private let ringBuffer = PCM16RingBuffer()
    private var engine: PicovoiceEngine?
    private var accumulated: [Int16] = []
    private var mode: SessionMode = .idle
    private var isRunning = false

    public init() {}

    public func start(accessKey: String) throws {
        let picovoice = try PicovoiceEngine(accessKey: accessKey)
        engine = picovoice
        accumulated.removeAll(keepingCapacity: true)
        accumulated.reserveCapacity(picovoice.frameLength * 2)
        try installTap(sampleRate: Double(picovoice.sampleRate))
        audioEngine.prepare()
        try audioEngine.start()
        isRunning = true
        mode = .idle
    }

    public func stop() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        engine = nil
        isRunning = false
        accumulated.removeAll(keepingCapacity: false)
        ringBuffer.clear()
        mode = .paused
    }

    public func beginResponse() { processingQueue.async { self.mode = .responding } }
    public func returnToIdle() { processingQueue.async { self.mode = .idle } }

    private func installTap(sampleRate: Double) throws {
        let input = audioEngine.inputNode
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            var pcm = [Int16]()
            pcm.reserveCapacity(count)
            for sample in UnsafeBufferPointer(start: channel, count: count) {
                pcm.append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
            }
            self?.processingQueue.async { self?.consume(pcm) }
        }
    }

    private func consume(_ pcm: [Int16]) {
        guard isRunning, let engine else { return }
        ringBuffer.append(pcm[...])
        accumulated.append(contentsOf: pcm)
        while accumulated.count >= engine.frameLength {
            let frame = accumulated.prefix(engine.frameLength)
            accumulated.removeFirst(engine.frameLength)
            do {
                let result = try engine.process(frame)
                evaluate(result: result)
            } catch {
                emit(.error(error))
                stop()
                return
            }
        }
    }

    private func evaluate(result: (keywordIndex: Int?, voiceProbability: Float)) {
        let now = ProcessInfo.processInfo.systemUptime
        switch mode {
        case .idle:
            if let index = result.keywordIndex {
                mode = .awaitingSpeech(deadline: now + policy.speechStartTimeout)
                emit(.wakeWord(index))
            }
        case .awaitingSpeech(let deadline):
            if result.voiceProbability >= policy.voiceThreshold {
                mode = .listening(startedAt: now, lastVoiceAt: now)
                emit(.speechStarted)
            } else if now >= deadline {
                mode = .idle
                emit(.waitingTimedOut)
            }
        case .listening(let startedAt, let lastVoiceAt):
            if result.voiceProbability >= policy.voiceThreshold {
                mode = .listening(startedAt: startedAt, lastVoiceAt: now)
            } else if now - lastVoiceAt >= policy.turnSilenceTimeout || now - startedAt >= policy.maximumTurnLength {
                mode = .responding
                emit(.turnEnded)
            }
        case .responding:
            if result.voiceProbability >= policy.voiceThreshold {
                mode = .idle
                emit(.speechDuringResponse)
            }
        case .paused:
            break
        }
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { self.onEvent?(event) }
    }
}
