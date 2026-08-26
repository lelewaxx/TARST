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

    public func process(
        keywordIndex: Int?,
        voiceProbability: Float,
        at now: TimeInterval,
        permitsBargeIn: Bool = true,
        prefersFastEndpoint: Bool = false
    ) -> SessionEffect {
        switch mode {
        case .idle:
            guard keywordIndex != nil else { return .none }
            mode = .awaitingSpeech(
                deadline: now + policy.speechStartTimeout,
                silenceStartedAt: nil,
                isReadyForSpeech: false,
                acceptSpeechAt: nil
            )
            return .wakeWordAccepted

        case .awaitingSpeech(let deadline, let silenceStartedAt, let isReadyForSpeech, let acceptSpeechAt):
            if now >= deadline {
                mode = .idle
                return .waitingTimedOut
            }

            // Playback drain is precise at the audio device but room echo can
            // reach the microphone for a few more frames. Ignore that short
            // tail by time, then accept speech immediately. AudioRuntime's
            // 0.5-second pre-roll preserves a user who starts during cooldown.
            if let acceptSpeechAt {
                guard now >= acceptSpeechAt else { return .none }
                if voiceProbability >= policy.voiceThreshold {
                    mode = .listening(startedAt: now, lastVoiceAt: now)
                    return .speechStarted
                }
                mode = .awaitingSpeech(
                    deadline: deadline,
                    silenceStartedAt: nil,
                    isReadyForSpeech: true,
                    acceptSpeechAt: nil
                )
                return .none
            }

            // The wake phrase itself still has a high VAD score for a few frames
            // after openWakeWord fires. Require a short quiet boundary before a
            // new voice segment can become the user's post-wake utterance.
            if !isReadyForSpeech {
                if voiceProbability >= policy.voiceThreshold {
                    mode = .awaitingSpeech(
                        deadline: deadline,
                        silenceStartedAt: nil,
                        isReadyForSpeech: false,
                        acceptSpeechAt: nil
                    )
                } else if let silenceStartedAt {
                    if now - silenceStartedAt >= policy.postWakeSilenceDuration {
                        mode = .awaitingSpeech(
                            deadline: deadline,
                            silenceStartedAt: silenceStartedAt,
                            isReadyForSpeech: true,
                            acceptSpeechAt: nil
                        )
                    }
                } else {
                    mode = .awaitingSpeech(
                        deadline: deadline,
                        silenceStartedAt: now,
                        isReadyForSpeech: false,
                        acceptSpeechAt: nil
                    )
                }
                return .none
            }

            if voiceProbability >= policy.voiceThreshold {
                mode = .listening(startedAt: now, lastVoiceAt: now)
                return .speechStarted
            }
            return .none

        case .listening(let startedAt, let lastVoiceAt):
            if now - startedAt >= policy.maximumTurnLength {
                mode = .responding(startedAt: now, voiceStartedAt: nil)
                return .turnEnded
            }
            if voiceProbability >= policy.voiceThreshold {
                mode = .listening(startedAt: startedAt, lastVoiceAt: now)
                return .none
            }
            let silenceTimeout = prefersFastEndpoint
                ? policy.punctuatedTurnSilenceTimeout
                : policy.turnSilenceTimeout
            if now - lastVoiceAt >= silenceTimeout {
                mode = .responding(startedAt: now, voiceStartedAt: nil)
                return .turnEnded
            }
            return .none

        case .responding(let startedAt, let voiceStartedAt):
            // Loudspeaker output is visible to the microphone on devices without
            // reliable acoustic echo cancellation. AudioRuntime disables barge-in
            // while PCM is actively being synthesized, queued, or played so TARST
            // cannot transcribe its own answer and recursively answer itself.
            guard permitsBargeIn else {
                mode = .responding(startedAt: startedAt, voiceStartedAt: nil)
                return .none
            }
            // Detector frames and callbacks are asynchronous. The first frame
            // after turnEnded can still belong to the just-finished utterance;
            // without a grace window it immediately cancels the response and
            // opens a duplicate ASR turn.
            guard now - startedAt >= policy.responseBargeInGracePeriod else { return .none }
            guard voiceProbability >= policy.voiceThreshold else {
                mode = .responding(startedAt: startedAt, voiceStartedAt: nil)
                return .none
            }
            guard let voiceStartedAt else {
                mode = .responding(startedAt: startedAt, voiceStartedAt: now)
                return .none
            }
            guard now - voiceStartedAt >= policy.bargeInConfirmationDuration else { return .none }
            // A barge-in is already the first voiced frame of the next turn.
            // Stay in the normal listening state so subsequent silence closes
            // that ASR stream; dropping to idle here required another wake word
            // and left the newly-opened ASR socket without a finish signal.
            mode = .listening(startedAt: now, lastVoiceAt: now)
            return .speechDuringResponse

        case .paused:
            return .none
        }
    }

    public func beginResponse(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        mode = .responding(startedAt: now, voiceStartedAt: nil)
    }
    public func responseFinished(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        mode = .awaitingSpeech(
            deadline: now + policy.followUpSpeechTimeout,
            silenceStartedAt: nil,
            // Unlike a wake phrase, playback has a precise drained boundary.
            // Accept an immediate follow-up so a user who speaks naturally at
            // the end of the answer does not lose their first words.
            isReadyForSpeech: true,
            acceptSpeechAt: now + policy.followUpEchoCooldown
        )
    }
    public func acceptBargeIn(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        mode = .listening(startedAt: now, lastVoiceAt: now)
    }
    public func pause() { mode = .paused }
    public func resume() { mode = .idle }
}
