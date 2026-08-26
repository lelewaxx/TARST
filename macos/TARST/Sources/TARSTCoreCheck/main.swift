import Foundation
import TARSTCore

let ringBuffer = PCM16RingBuffer(sampleRate: 10, seconds: 1)
ringBuffer.append([1, 2, 3, 4, 5, 6][...])
ringBuffer.append([7, 8, 9, 10, 11][...])
precondition(ringBuffer.sampleCount == 10, "ring buffer must retain only 1.5 seconds of audio")
ringBuffer.clear()
precondition(ringBuffer.sampleCount == 0, "ring buffer must clear all in-memory audio")

let session = SessionController()
precondition(session.process(keywordIndex: 0, voiceProbability: 0, at: 0) == .wakeWordAccepted)
precondition(session.process(keywordIndex: nil, voiceProbability: 0, at: 5.9) == .none)
precondition(session.process(keywordIndex: nil, voiceProbability: 0, at: 6.0) == .waitingTimedOut)
precondition(session.process(keywordIndex: 1, voiceProbability: 0, at: 10) == .wakeWordAccepted)
precondition(session.process(keywordIndex: nil, voiceProbability: 0.8, at: 10.1) == .none, "wake tail must not start speech")
precondition(session.process(keywordIndex: nil, voiceProbability: 0, at: 10.2) == .none)
precondition(session.process(keywordIndex: nil, voiceProbability: 0, at: 10.37) == .none)
precondition(session.process(keywordIndex: nil, voiceProbability: 0.8, at: 10.45) == .speechStarted)
precondition(session.process(keywordIndex: nil, voiceProbability: 0, at: 11.64) == .none)
precondition(session.process(keywordIndex: nil, voiceProbability: 0, at: 11.66) == .turnEnded)
precondition(
    session.process(keywordIndex: nil, voiceProbability: 0.9, at: 11.7, permitsBargeIn: false) == .none,
    "speaker playback must not become a user interruption"
)
precondition(
    session.process(keywordIndex: nil, voiceProbability: 0.9, at: 11.8) == .none,
    "the previous utterance tail must not become a user interruption"
)
precondition(
    session.process(keywordIndex: nil, voiceProbability: 0.9, at: 12.5) == .none,
    "a single echo spike must not interrupt playback"
)
precondition(session.process(keywordIndex: nil, voiceProbability: 0.9, at: 12.6) == .none)
precondition(session.process(keywordIndex: nil, voiceProbability: 0.9, at: 12.76) == .speechDuringResponse)
precondition(session.process(keywordIndex: nil, voiceProbability: 0, at: 13.97) == .turnEnded, "barge-in must become a complete next turn")
session.responseFinished(at: 20)
precondition(
    session.process(keywordIndex: nil, voiceProbability: 0.9, at: 20.1) == .none,
    "speaker tail immediately after playback drain must not open a phantom turn"
)
precondition(session.process(keywordIndex: nil, voiceProbability: 0.9, at: 20.27) == .none)
precondition(
    session.process(keywordIndex: nil, voiceProbability: 0.9, at: 20.4) == .speechStarted,
    "a completed response must accept a follow-up without another wake word"
)
precondition(session.process(keywordIndex: nil, voiceProbability: 0.9, at: 65.5) == .turnEnded)
session.responseFinished(at: 70)
precondition(
    session.process(keywordIndex: nil, voiceProbability: 0, at: 100) == .waitingTimedOut,
    "an inactive follow-up window must eventually return to wake-word standby"
)

let fastEndpointSession = SessionController()
precondition(fastEndpointSession.process(keywordIndex: 0, voiceProbability: 0, at: 0) == .wakeWordAccepted)
precondition(fastEndpointSession.process(keywordIndex: nil, voiceProbability: 0, at: 0.1) == .none)
precondition(fastEndpointSession.process(keywordIndex: nil, voiceProbability: 0, at: 0.27) == .none)
precondition(fastEndpointSession.process(keywordIndex: nil, voiceProbability: 0.9, at: 0.4) == .speechStarted)
precondition(
    fastEndpointSession.process(
        keywordIndex: nil,
        voiceProbability: 0,
        at: 1.06,
        prefersFastEndpoint: true
    ) == .turnEnded,
    "a punctuated stable transcript should use the 650 ms endpoint"
)

let diagnosticsDirectory = FileManager.default.temporaryDirectory
    .appending(path: "tarst-diagnostics-\(UUID().uuidString)", directoryHint: .isDirectory)
defer { try? FileManager.default.removeItem(at: diagnosticsDirectory) }
let diagnostics = DiagnosticsRecorder(directory: diagnosticsDirectory)
let diagnosticsFile = try diagnostics.start(metadata: ["contains_audio": false])
diagnostics.recordFrame(wakeScores: [0.12, 0.34], voiceProbability: 0.56, keywordIndex: nil)
diagnostics.recordEvent("wake_accepted", fields: ["keyword_index": 1])
diagnostics.stop()
let diagnosticContents = try String(contentsOf: diagnosticsFile, encoding: .utf8)
let diagnosticLines = diagnosticContents.split(separator: "\n")
precondition(diagnosticLines.count == 4, "diagnostics must contain session, frame, event, and stop records")
let diagnosticFrame = try JSONSerialization.jsonObject(with: Data(diagnosticLines[1].utf8)) as! [String: Any]
let tarstScore = (diagnosticFrame["tarst_score"] as! NSNumber).doubleValue
let heyTarstScore = (diagnosticFrame["hey_tarst_score"] as! NSNumber).doubleValue
let vadProbability = (diagnosticFrame["vad_probability"] as! NSNumber).doubleValue
precondition(abs(tarstScore - 0.12) < 0.001, "diagnostics must retain TARST scores")
precondition(abs(heyTarstScore - 0.34) < 0.001, "diagnostics must retain Hey-TARST scores")
precondition(abs(vadProbability - 0.56) < 0.001, "diagnostics must retain VAD scores")
precondition(!diagnosticContents.localizedCaseInsensitiveContains("pcm"), "diagnostics must not contain PCM")
precondition(!diagnosticContents.localizedCaseInsensitiveContains("transcript"), "diagnostics must not contain transcripts")
precondition(!diagnosticContents.localizedCaseInsensitiveContains("raw_audio"), "diagnostics must not contain raw audio")

precondition(MiniMaxCredentials(apiKey: "  test-key  ").normalized.apiKey == "test-key", "MiniMax key must normalize")
precondition(MiniMaxCredentials(apiKey: "").isComplete == false, "empty MiniMax key must be incomplete")

precondition(
    InterruptionTextClassifier.classify(
        candidate: "今天天气很好，我们可以出去散步。",
        spokenResponse: "今天天气很好，我们可以出去散步。记得带一件外套。"
    ) == .echo,
    "spoken response fragments must be classified as echo"
)
precondition(
    InterruptionTextClassifier.classify(
        candidate: "等等，我想换一个问题。",
        spokenResponse: "今天天气很好，我们可以出去散步。"
    ) == .user,
    "an explicit user interruption must not be classified as echo"
)
precondition(
    InterruptionTextClassifier.classify(candidate: "天气", spokenResponse: "今天天气很好。") == .undetermined,
    "short ambiguous fragments must wait for more ASR context"
)
var interruptionProbe = InterruptionProbeTracker()
let spokenAnswer = "今天天气很好我们可以出去散步记得带一件外套"
precondition(
    interruptionProbe.observe(candidate: "今天天气很好我们可以出去", spokenResponse: spokenAnswer) == .echo
)
precondition(
    interruptionProbe.observe(candidate: "今天天气很好我们可以出去你再说点", spokenResponse: spokenAnswer) == .suspectedUser,
    "one anchored ASR divergence should pause but not cancel playback"
)
precondition(
    interruptionProbe.observe(candidate: "今天天气很好我们可以出去你再说点别的吧", spokenResponse: spokenAnswer) == .user,
    "a progressive user suffix after cumulative echo must interrupt playback"
)
interruptionProbe.reset()
precondition(
    interruptionProbe.observe(candidate: "今天天气很好停一下", spokenResponse: spokenAnswer) == .user,
    "an explicit interruption phrase must stop playback immediately"
)
interruptionProbe.reset()
precondition(
    interruptionProbe.observe(
        candidate: "今天天气很好我们可以出去散步这样就好了",
        spokenResponse: "今天天气很好我们可以出去散步这样就好了记得带外套"
    ) == .echo,
    "an interruption phrase spoken by TARST itself must remain echo"
)
interruptionProbe.reset()
precondition(
    interruptionProbe.observe(
        candidate: "识别有一点偏差但是仍像扬声器的一整段较长文本",
        spokenResponse: "识别有一些偏差但是仍像扬声器的一整段较长文本"
    ) != .user,
    "one unanchored recognition revision must not cancel playback"
)
interruptionProbe.reset()
precondition(
    interruptionProbe.observe(candidate: "我想换个", spokenResponse: spokenAnswer) == .undetermined
)
precondition(
    interruptionProbe.observe(candidate: "我想换个问题", spokenResponse: spokenAnswer) == .undetermined,
    "two short unanchored partials must not cancel playback"
)
precondition(
    interruptionProbe.observe(
        candidate: "我想换个问题请先听我说接下来聊什么",
        spokenResponse: spokenAnswer
    ) == .suspectedUser,
    "three long unanchored revisions may pause but must not cancel playback"
)
precondition(
    interruptionProbe.observe(
        candidate: "我想换个问题请先听我说接下来聊什么别再继续了",
        spokenResponse: spokenAnswer
    ) == .user,
    "a sustained long unanchored user utterance must still interrupt playback"
)
interruptionProbe.reset()
precondition(
    interruptionProbe.observe(
        candidate: "这是塔斯回升自动测验系统正在播放",
        spokenResponse: "这是TARST回声消除自动测试。系统正在播放一段完整语音。"
    ) == .echo,
    "isolated ASR substitutions in loudspeaker speech must remain echo"
)

var chunker = ChineseSentenceChunker()
precondition(chunker.append("你好，今天") == [], "partial sentence must remain buffered")
precondition(chunker.append("天气很好。我们") == ["你好，今天天气很好。"], "punctuation must flush a complete sentence")
precondition(chunker.finish() == ["我们"], "finish must flush the remaining sentence")

var phraseChunker = ChineseSentenceChunker()
precondition(phraseChunker.append("先说结论，这项改动可以") == [], "a short leading comma must not create a choppy phrase")
precondition(
    phraseChunker.append("让语音更快，后面继续解释") == ["先说结论，这项改动可以让语音更快，"],
    "a stable comma-delimited phrase must reach TTS before the full sentence"
)
precondition(phraseChunker.finish() == ["后面继续解释"], "phrase remainder must be preserved exactly")

func v3Frame(type: UInt8, event: UInt32, payload: Data = Data()) -> Data {
    var data = Data([0x11, type, 0x10, 0x00])
    data.append(contentsOf: [
        UInt8(truncatingIfNeeded: event >> 24), UInt8(truncatingIfNeeded: event >> 16),
        UInt8(truncatingIfNeeded: event >> 8), UInt8(truncatingIfNeeded: event),
        UInt8(truncatingIfNeeded: UInt32(payload.count) >> 24), UInt8(truncatingIfNeeded: UInt32(payload.count) >> 16),
        UInt8(truncatingIfNeeded: UInt32(payload.count) >> 8), UInt8(truncatingIfNeeded: UInt32(payload.count)),
    ])
    data.append(payload)
    return data
}
precondition(VolcengineTTSWire.parse(Data([0x11, 0x10, 0x10, 0, 0, 0, 1, 103])) == .ttsEnded, "payload-less V3 TTS end frame must parse")
precondition(VolcengineTTSWire.parse(Data([0x11, 0x10, 0x10, 0, 0, 0, 0, 152])) == .sessionFinished, "payload-less V3 session end frame must parse")
precondition(VolcengineTTSWire.parse(Data([0x11, 0x10, 0x10, 0, 0, 0, 0, 52])) == .connectionFinished, "payload-less V3 connection end frame must parse")
precondition(VolcengineTTSWire.parse(v3Frame(type: 0xB0, event: 352, payload: Data([1, 2, 3]))) == .audio(Data([1, 2, 3])), "V3 PCM frame must retain all bytes")
precondition(VolcengineTTSWire.parse(v3Frame(type: 0x10, event: 50)) == .connectionStarted, "V3 connection event must be recognized")
precondition(VolcengineTTSWire.parse(v3Frame(type: 0x10, event: 150)) == .sessionStarted, "V3 session event must be recognized")
let taskPacket = VolcengineTTSWire.packet(event: 200, sessionID: "session", payload: Data("{}".utf8))
precondition(taskPacket.count > 12, "V3 task request must contain its event, session, and payload")
print("TARST core checks passed")
