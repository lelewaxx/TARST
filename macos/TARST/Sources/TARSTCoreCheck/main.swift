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
precondition(session.process(keywordIndex: nil, voiceProbability: 0.8, at: 10.1) == .speechStarted)
precondition(session.process(keywordIndex: nil, voiceProbability: 0, at: 11.8) == .none)
precondition(session.process(keywordIndex: nil, voiceProbability: 0, at: 11.91) == .turnEnded)
precondition(session.process(keywordIndex: nil, voiceProbability: 0.9, at: 12) == .speechDuringResponse)
precondition(session.process(keywordIndex: 0, voiceProbability: 0, at: 20) == .wakeWordAccepted)
precondition(session.process(keywordIndex: nil, voiceProbability: 0.9, at: 20.1) == .speechStarted)
precondition(session.process(keywordIndex: nil, voiceProbability: 0.9, at: 65.2) == .turnEnded)
print("TARST core checks passed")
