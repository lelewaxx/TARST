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
    private let ringBuffer = PCM16RingBuffer()
    private var detector: LocalVoiceDetector?
    private var accumulated: [Int16] = []
    private let session = SessionController()
    private var isRunning = false

    public init() {}

    public func start() throws {
        let localDetector = try LocalVoiceDetector()
        localDetector.onEvent = { [weak self] event in
            self?.processingQueue.async { self?.consume(event) }
        }
        detector = localDetector
        accumulated.removeAll(keepingCapacity: true)
        accumulated.reserveCapacity(1280 * 2)
        try installTap(sampleRate: 16_000)
        audioEngine.prepare()
        try audioEngine.start()
        isRunning = true
        session.resume()
    }

    public func stop() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        detector?.stop()
        detector = nil
        isRunning = false
        accumulated.removeAll(keepingCapacity: false)
        ringBuffer.clear()
        session.pause()
    }

    public func beginResponse() { processingQueue.async { self.session.beginResponse() } }
    public func returnToIdle() { processingQueue.async { self.session.responseFinished() } }

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
        guard isRunning, detector != nil else { return }
        ringBuffer.append(pcm[...])
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
        case .prediction(let keywordIndex, let voiceProbability):
            evaluate(keywordIndex: keywordIndex, voiceProbability: voiceProbability)
        case .error(let message):
            emit(.error(LocalVoiceDetectorError.failedToStart(message)))
        }
    }

    private func evaluate(keywordIndex: Int?, voiceProbability: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        let effect = session.process(keywordIndex: keywordIndex, voiceProbability: voiceProbability, at: now)
        switch effect {
        case .none: break
        case .wakeWordAccepted: emit(.wakeWord(keywordIndex ?? 0))
        case .speechStarted: emit(.speechStarted)
        case .turnEnded: emit(.turnEnded)
        case .speechDuringResponse: emit(.speechDuringResponse)
        case .waitingTimedOut: emit(.waitingTimedOut)
        }
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { self.onEvent?(event) }
    }
}
