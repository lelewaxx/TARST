import AVFoundation
import AudioToolbox
import CoreAudio

public final class PCMPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private let stateLock = NSLock()
    private var queuedBufferCount = 0
    private var playbackGeneration = 0
    private var echoReference = EchoReferenceOutput(deviceName: "ReSpeaker Lite")

    /// Called after the final scheduled PCM buffer has actually reached the
    /// output device. WebSocket completion alone is not enough: it only means
    /// all bytes were received, not that the listener has heard them.
    public var onQueueDrained: (() -> Void)?

    public init() { engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format) }

    public var isDrained: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return queuedBufferCount == 0
    }

    /// True when TARST can send the exact far-end PCM stream to ReSpeaker
    /// Lite's USB output. Its onboard XU316 AEC uses that reference to remove
    /// loudspeaker echo from the microphone while preserving user speech.
    public var hasHardwareEchoReference: Bool { echoReference != nil }

    public func play(_ data: Data) throws {
        let frames = AVAudioFrameCount(data.count / 2)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        data.copyBytes(to: UnsafeMutableRawBufferPointer(start: buffer.int16ChannelData![0], count: Int(frames) * 2))

        stateLock.lock()
        let generation = playbackGeneration
        queuedBufferCount += 1
        stateLock.unlock()

        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.didFinishBuffer(generation: generation)
        }
        if !engine.isRunning { try engine.start() }
        if !node.isPlaying { node.play() }
        if let reference = echoReference {
            do {
                try reference.play(data)
            } catch {
                reference.stop()
                echoReference = nil
            }
        }
    }

    public func stop() {
        stateLock.lock()
        playbackGeneration += 1
        queuedBufferCount = 0
        stateLock.unlock()
        node.stop()
        engine.stop()
        echoReference?.stop()
    }

    public func pause() {
        guard !isDrained else { return }
        node.pause()
        echoReference?.pause()
    }

    public func resume() {
        guard !isDrained else { return }
        if !engine.isRunning { try? engine.start() }
        if !node.isPlaying { node.play() }
        echoReference?.resume()
    }

    private func didFinishBuffer(generation: Int) {
        stateLock.lock()
        guard generation == playbackGeneration else {
            stateLock.unlock()
            return
        }
        queuedBufferCount = max(0, queuedBufferCount - 1)
        let drained = queuedBufferCount == 0
        stateLock.unlock()
        if drained { onQueueDrained?() }
    }
}

private final class EchoReferenceOutput {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: true
    )!

    init?(deviceName: String) {
        guard let deviceID = Self.audioDeviceID(named: deviceName),
              let audioUnit = engine.outputNode.audioUnit else { return nil }
        var selectedDevice = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDevice,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { return nil }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func play(_ data: Data) throws {
        let frames = AVAudioFrameCount(data.count / 2)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        data.copyBytes(to: UnsafeMutableRawBufferPointer(
            start: buffer.int16ChannelData![0],
            count: Int(frames) * 2
        ))
        node.scheduleBuffer(buffer)
        if !engine.isRunning { try engine.start() }
        if !node.isPlaying { node.play() }
    }

    func stop() {
        node.stop()
        engine.stop()
    }

    func pause() { node.pause() }

    func resume() {
        if !engine.isRunning { try? engine.start() }
        if !node.isPlaying { node.play() }
    }

    private static func audioDeviceID(named targetName: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return nil }
        var devices = [AudioDeviceID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &devices
        ) == noErr else { return nil }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for device in devices {
            var unmanagedName: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(
                device,
                &nameAddress,
                0,
                nil,
                &nameSize,
                &unmanagedName
            ) == noErr, let name = unmanagedName?.takeUnretainedValue() else { continue }
            if (name as String) == targetName { return device }
        }
        return nil
    }
}
