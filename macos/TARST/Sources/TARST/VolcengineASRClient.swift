import Foundation

public enum VolcengineASRError: LocalizedError {
    case invalidCredentials
    case invalidResponse
    case service(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials: "火山引擎 ASR 尚未配置。"
        case .invalidResponse: "火山引擎 ASR 返回了无法识别的响应。"
        case .service(let code): "火山引擎 ASR 服务错误（\(code)）。"
        }
    }
}

/// Streams 16 kHz / 16-bit / mono PCM to Volcengine BigModel ASR. It retains no
/// audio after `send` returns. Local VAD owns turn boundaries; the server is only
/// asked to transcribe the caller-supplied turn.
public final class VolcengineASRClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    public enum Event: Sendable {
        case partial(String)
        case final(String)
        case failure(Error)
    }

    public var onEvent: ((Event) -> Void)?
    private let stateQueue = DispatchQueue(label: "com.tarst.volcengine-asr")
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var outgoingPackets: [Data] = []
    private var isOpen = false
    private var isSending = false
    private var hasFinished = false
    private var wasStopped = false
    private var terminalEventEmitted = false
    private var lastText = ""

    public func start(credentials: VolcengineVoiceCredentials) throws {
        let value = credentials.normalized
        guard value.isASRComplete else { throw VolcengineASRError.invalidCredentials }
        let requestID = UUID().uuidString
        var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel")!)
        request.setValue(value.appID, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(value.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(value.asrResourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(requestID, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue(requestID, forHTTPHeaderField: "X-Api-Connect-Id")

        let configuration: [String: Any] = [
            "user": ["uid": "tarst-local"],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16_000, "bits": 16, "channel": 1],
            "request": [
                "model_name": "bigmodel", "enable_itn": true, "enable_punc": true,
                "enable_ddc": false, "show_utterances": true, "result_type": "full"
            ]
        ]
        let json = try JSONSerialization.data(withJSONObject: configuration)
        let initialPacket = VolcengineASRWire.packet(type: 0x1, flags: 0, payload: json)
        let urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let websocket = urlSession.webSocketTask(with: request)
        stateQueue.sync {
            session = urlSession
            task = websocket
            outgoingPackets = [initialPacket]
            isOpen = false
            isSending = false
            hasFinished = false
            wasStopped = false
            terminalEventEmitted = false
            lastText = ""
        }
        websocket.resume()
        receiveNext(from: websocket)
    }

    public func send(pcm: [Int16]) {
        guard !pcm.isEmpty else { return }
        let audio = pcm.withUnsafeBytes { Data($0) }
        let packet = VolcengineASRWire.packet(type: 0x2, flags: 0, payload: audio)
        stateQueue.async { [weak self] in
            guard let self, !self.hasFinished, !self.wasStopped, self.task != nil else { return }
            self.outgoingPackets.append(packet)
            self.sendNextLocked()
        }
    }

    public func finish() {
        let packet = VolcengineASRWire.packet(type: 0x2, flags: 0x2, payload: Data())
        stateQueue.async { [weak self] in
            guard let self, !self.hasFinished, !self.wasStopped, self.task != nil else { return }
            // Queue the terminal packet behind every audio packet. This also
            // handles a short utterance ending before didOpenWithProtocol.
            self.hasFinished = true
            self.outgoingPackets.append(packet)
            self.sendNextLocked()
        }
    }

    public func stop() {
        stateQueue.async { [weak self] in self?.stopLocked() }
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        stateQueue.async { [weak self, weak webSocketTask] in
            guard let self, let webSocketTask, self.task === webSocketTask, !self.wasStopped else { return }
            self.isOpen = true
            self.sendNextLocked()
        }
    }

    private func sendNextLocked() {
        guard isOpen, !isSending, !outgoingPackets.isEmpty, let socket = task else { return }
        isSending = true
        let packet = outgoingPackets.removeFirst()
        socket.send(.data(packet)) { [weak self, weak socket] error in
            guard let self, let socket else { return }
            self.stateQueue.async {
                guard self.task === socket else { return }
                self.isSending = false
                if let error {
                    self.failLocked(error)
                } else {
                    self.sendNextLocked()
                }
            }
        }
    }

    private func receiveNext(from socket: URLSessionWebSocketTask) {
        socket.receive { [weak self, weak socket] result in
            guard let self, let socket else { return }
            self.stateQueue.async {
                guard self.task === socket else { return }
                switch result {
                case .success(.data(let data)):
                    self.handleLocked(data)
                    if self.task === socket { self.receiveNext(from: socket) }
                case .success:
                    self.failLocked(VolcengineASRError.invalidResponse)
                case .failure(let error):
                    // `stop()` follows a final response and explicit barge-in.
                    // Cancellation callbacks from those paths are not failures.
                    if !self.wasStopped { self.failLocked(error) }
                }
            }
        }
    }

    private func handleLocked(_ data: Data) {
        do {
            let response = try VolcengineASRWire.response(from: data)
            if let code = response.errorCode { failLocked(VolcengineASRError.service(code)); return }
            guard let payload = response.payload,
                  let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
            let text = ((object["result"] as? [String: Any])?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            lastText = text
            if response.isFinal {
                guard !terminalEventEmitted else { return }
                terminalEventEmitted = true
                emit(.final(text))
                stopLocked()
            } else {
                emit(.partial(text))
            }
        } catch { failLocked(error) }
    }

    private func failLocked(_ error: Error) {
        guard !terminalEventEmitted, !wasStopped else { return }
        terminalEventEmitted = true
        emit(.failure(error))
        stopLocked()
    }

    private func stopLocked() {
        wasStopped = true
        hasFinished = true
        isOpen = false
        isSending = false
        outgoingPackets.removeAll(keepingCapacity: false)
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func emit(_ event: Event) { DispatchQueue.main.async { self.onEvent?(event) } }
}

enum VolcengineASRWire {
    static func packet(type: UInt8, flags: UInt8, payload: Data) -> Data {
        // Protocol V1, 4-byte header, JSON/PCM payload deliberately uncompressed.
        var data = Data([0x11, (type << 4) | flags, 0x10, 0x00])
        data.appendUInt32BE(UInt32(payload.count))
        data.append(payload)
        return data
    }

    static func response(from data: Data) throws -> (payload: Data?, isFinal: Bool, errorCode: Int?) {
        guard data.count >= 4 else { throw VolcengineASRError.invalidResponse }
        let type = data[1] >> 4
        let flags = data[1] & 0x0F
        if type == 0xF {
            guard data.count >= 8 else { throw VolcengineASRError.invalidResponse }
            return (nil, true, Int(data.uint32BE(at: 4)))
        }
        guard type == 0x9 else { return (nil, false, nil) }
        var offset = 4
        if flags & 0x1 != 0 { offset += 4 }
        guard data.count >= offset + 4 else { throw VolcengineASRError.invalidResponse }
        let size = Int(data.uint32BE(at: offset)); offset += 4
        guard size >= 0, data.count >= offset + size else { throw VolcengineASRError.invalidResponse }
        // The client requests no compression (header compression=0), so payloads
        // are JSON directly. A compressed response is rejected safely instead of
        // trying to interpret bytes as a transcript.
        guard data[2] & 0x0F == 0 else { throw VolcengineASRError.invalidResponse }
        return (data.subdata(in: offset..<(offset + size)), flags & 0x2 != 0, nil)
    }
}

private extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        // UInt8(_:), unlike a C cast, traps when the source does not fit.
        // A length field must intentionally take each individual byte.
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
    }
    func uint32BE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }
}
