import Foundation

public final class VolcengineTTSClient {
    public enum Event { case ready; case audio(Data); case finished; case failure(Error) }
    public var onEvent: ((Event) -> Void)?
    private var task: URLSessionWebSocketTask?
    private var sessionID: String?
    private var credentials: VolcengineVoiceCredentials?
    private var pendingText = ""
    private var connectionReady = false
    private var sessionActive = false
    private var wasStopped = false
    public init() {}

    /// Opens the connection layer without starting a synthesis session. Keeping
    /// this warm across companion turns removes TCP/TLS/WebSocket setup from the
    /// user's perceived response latency.
    public func prepare(credentials: VolcengineVoiceCredentials) throws {
        let value = credentials.normalized
        guard value.isTTSComplete else { throw VolcengineASRError.invalidCredentials }
        self.credentials = value
        guard task == nil else { return }
        try connect()
    }

    public func synthesize(_ text: String, credentials: VolcengineVoiceCredentials) throws {
        let value = credentials.normalized
        guard value.isTTSComplete else { throw VolcengineASRError.invalidCredentials }
        guard !sessionActive, pendingText.isEmpty else {
            throw NSError(
                domain: "TARST.TTS",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "上一段语音尚未结束。"]
            )
        }
        self.credentials = value
        pendingText = text
        wasStopped = false
        if task == nil { try connect() }
        if connectionReady { startSession() }
    }

    private func connect() throws {
        guard let value = credentials else { throw VolcengineASRError.invalidCredentials }
        var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/tts/bidirection")!)
        let id = UUID().uuidString
        request.setValue(value.appID, forHTTPHeaderField: "X-Api-App-Key"); request.setValue(value.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(value.ttsResourceID, forHTTPHeaderField: "X-Api-Resource-Id"); request.setValue(id, forHTTPHeaderField: "X-Api-Connect-Id")
        let ws = URLSession.shared.webSocketTask(with: request); task = ws
        connectionReady = false
        sessionActive = false
        wasStopped = false
        ws.resume()
        receive()
        send(event: 1, session: nil, payload: [:])
    }

    public func cancel() {
        wasStopped = true
        if let sessionID, sessionActive { send(event: 101, session: sessionID, payload: [:]) }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        sessionID = nil
        pendingText = ""
        connectionReady = false
        sessionActive = false
    }
    private func send(event: Int, session: String?, payload: [String: Any], attempt: Int = 0) {
        guard let task, let json = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let data = VolcengineTTSWire.packet(event: event, sessionID: session, payload: json)
        task.send(.data(data)) { [weak self] error in
            guard let self, let error else { return }
            if attempt < 5, error.localizedDescription.localizedCaseInsensitiveContains("socket is not connected") {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) { self.send(event: event, session: session, payload: payload, attempt: attempt + 1) }
            } else { self.fail(error) }
        }
    }
    private func receive() { task?.receive { [weak self] result in guard let self else{return}; switch result { case .success(.data(let data)): self.parse(data); if self.task != nil { self.receive() }; case .success(.string(let value)): self.fail(NSError(domain: "TARST.TTS", code: 1, userInfo: [NSLocalizedDescriptionKey: String(value.prefix(240))])); case .failure(let e): if !self.wasStopped { self.fail(e) }; @unknown default: self.fail(VolcengineASRError.invalidResponse) } } }
    private func parse(_ data: Data) {
        switch VolcengineTTSWire.parse(data) {
        case .connectionStarted:
            connectionReady = true
            emit(.ready)
            if !pendingText.isEmpty { startSession() }
        case .sessionStarted:
            guard let sessionID else { return }
            send(event: 200, session: sessionID, payload: ["req_params": ["text": pendingText]])
            send(event: 102, session: sessionID, payload: [:])
        case .audio(let pcm):
            emit(.audio(pcm))
        case .ttsEnded:
            break
        case .sessionFinished:
            finishSession()
        case .connectionFinished:
            task?.cancel(with: .normalClosure, reason: nil)
            task = nil
            connectionReady = false
        case .other, .invalid:
            break
        }
    }

    private func startSession() {
        guard connectionReady, !sessionActive, !pendingText.isEmpty, let credentials else { return }
        let id = UUID().uuidString
        sessionID = id
        sessionActive = true
        send(event: 100, session: id, payload: [
            "user": ["uid": "tarst-local"], "event": 100,
            "namespace": "BidirectionalTTS",
            "req_params": ["speaker": credentials.ttsVoiceType,
                           "audio_params": ["format": "pcm", "sample_rate": 24_000]],
        ])
    }

    private func finishSession() {
        guard sessionActive else { return }
        sessionActive = false
        sessionID = nil
        pendingText = ""
        emit(.finished)
    }

    private func fail(_ error: Error) {
        let shouldReport = sessionActive || !pendingText.isEmpty
        task = nil
        sessionID = nil
        connectionReady = false
        sessionActive = false
        if shouldReport { emit(.failure(error)) }
    }
    private func emit(_ event: Event) { DispatchQueue.main.async { self.onEvent?(event) } }
}

/// Stateless V3 wire codec. Kept separate from URLSession so malformed and
/// terminal frames can be regression-tested without network credentials.
public enum VolcengineTTSWire {
    public enum Incoming: Equatable {
        case connectionStarted
        case sessionStarted
        case audio(Data)
        case ttsEnded
        case sessionFinished
        case connectionFinished
        case other
        case invalid
    }

    public static func packet(event: Int, sessionID: String?, payload: Data) -> Data {
        var data = Data([0x11, 0x14, 0x10, 0])
        data.appendInt32(event)
        if let sessionID {
            let id = Data(sessionID.utf8)
            data.appendUInt32(UInt32(id.count))
            data.append(id)
        }
        data.appendUInt32(UInt32(payload.count))
        data.append(payload)
        return data
    }

    public static func parse(_ data: Data) -> Incoming {
        guard data.count >= 8 else { return .invalid }
        let type = data[1] >> 4
        let event = Int(data.int32(at: 4))
        // V3's `TTSEnded` and `SessionFinished` frames are allowed to omit a
        // payload. Recognize them before trying to decode optional fields.
        if event == 359 { return .ttsEnded }
        if event == 152 { return .sessionFinished }
        if event == 52 { return .connectionFinished }

        var offset = 8
        if data[1] & 4 != 0 {
            guard data.count >= offset + 4 else { return .invalid }
            let sessionLength = Int(data.uint32(at: offset))
            offset += 4 + sessionLength
            guard data.count >= offset else { return .invalid }
        }
        guard data.count >= offset + 4 else { return .invalid }
        let payloadLength = Int(data.uint32(at: offset))
        offset += 4
        guard data.count >= offset + payloadLength else { return .invalid }

        switch event {
        case 50: return .connectionStarted
        case 150: return .sessionStarted
        case 352 where type == 0xB: return .audio(data.subdata(in: offset..<(offset + payloadLength)))
        default: return .other
        }
    }
}

private extension Data { mutating func appendUInt32(_ v: UInt32){ append(contentsOf:[UInt8(truncatingIfNeeded:v>>24),UInt8(truncatingIfNeeded:v>>16),UInt8(truncatingIfNeeded:v>>8),UInt8(truncatingIfNeeded:v)]) }; mutating func appendInt32(_ v:Int){ appendUInt32(UInt32(bitPattern:Int32(v))) }; func uint32(at i:Int)->UInt32 { UInt32(self[i])<<24|UInt32(self[i+1])<<16|UInt32(self[i+2])<<8|UInt32(self[i+3]) }; func int32(at i:Int)->Int32 { Int32(bitPattern:uint32(at:i)) } }
