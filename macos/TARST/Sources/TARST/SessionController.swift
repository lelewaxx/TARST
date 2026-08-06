import Foundation

public enum SessionEffect: Equatable {
    case none
    case wakeWordAccepted
    case speechStarted
    case turnEnded
    case speechDuringResponse
    case waitingTimedOut
}

/// Deterministic interaction policy, kept separate from microphone and Picovoice adapters.
public final class SessionController {
    private let policy = SessionPolicy()
    private var mode: SessionMode = .idle

    public init() {}

    public func process(keywordIndex: Int?, voiceProbability: Float, at now: TimeInterval) -> SessionEffect {
        switch mode {
        case .idle:
            guard keywordIndex != nil else { return .none }
            mode = .awaitingSpeech(deadline: now + policy.speechStartTimeout)
            return .wakeWordAccepted

        case .awaitingSpeech(let deadline):
            if voiceProbability >= policy.voiceThreshold {
                mode = .listening(startedAt: now, lastVoiceAt: now)
                return .speechStarted
            }
            if now >= deadline {
                mode = .idle
                return .waitingTimedOut
            }
            return .none

        case .listening(let startedAt, let lastVoiceAt):
            if now - startedAt >= policy.maximumTurnLength {
                mode = .responding
                return .turnEnded
            }
            if voiceProbability >= policy.voiceThreshold {
                mode = .listening(startedAt: startedAt, lastVoiceAt: now)
                return .none
            }
            if now - lastVoiceAt >= policy.turnSilenceTimeout {
                mode = .responding
                return .turnEnded
            }
            return .none

        case .responding:
            guard voiceProbability >= policy.voiceThreshold else { return .none }
            mode = .idle
            return .speechDuringResponse

        case .paused:
            return .none
        }
    }

    public func beginResponse() { mode = .responding }
    public func responseFinished() { mode = .idle }
    public func pause() { mode = .paused }
    public func resume() { mode = .idle }
}
