import Foundation

public enum TARSTStatus: Equatable {
    case needsSetup
    case idle
    case awaitingSpeech
    case listening
    case transcribing
    case responding
    case paused
    case error(String)

    public var title: String {
        switch self {
        case .needsSetup: "需要设置"
        case .idle: "待命"
        case .awaitingSpeech: "我在听"
        case .listening: "正在倾听"
        case .transcribing: "正在转写"
        case .responding: "正在回应"
        case .paused: "已暂停"
        case .error: "需要注意"
        }
    }

    public var icon: String {
        switch self {
        case .listening, .awaitingSpeech: "ear.fill"
        case .transcribing: "text.line.first.and.arrowtriangle.forward"
        case .responding: "waveform"
        case .paused: "pause.circle"
        case .error, .needsSetup: "exclamationmark.circle"
        case .idle: "moon.stars"
        }
    }
}

enum SessionMode: Equatable {
    case idle
    case awaitingSpeech(
        deadline: TimeInterval,
        silenceStartedAt: TimeInterval?,
        isReadyForSpeech: Bool,
        acceptSpeechAt: TimeInterval?
    )
    case listening(startedAt: TimeInterval, lastVoiceAt: TimeInterval)
    case responding(startedAt: TimeInterval, voiceStartedAt: TimeInterval?)
    case paused
}

struct SessionPolicy {
    let speechStartTimeout: TimeInterval = 6
    let postWakeSilenceDuration: TimeInterval = 0.16
    // 1.8 s felt sluggish in normal Chinese conversation. 1.2 s still tolerates
    // a natural phrase pause while removing 600 ms from every completed turn.
    let turnSilenceTimeout: TimeInterval = 1.2
    let punctuatedTurnSilenceTimeout: TimeInterval = 0.65
    let maximumTurnLength: TimeInterval = 45
    let voiceThreshold: Float = 0.5
    let responseBargeInGracePeriod: TimeInterval = 0.8
    let bargeInConfirmationDuration: TimeInterval = 0.24
    /// Keep a wake-word session conversational after each answer. A quiet
    /// timeout closes the session so an unattended microphone does not remain
    /// command-active indefinitely.
    let followUpSpeechTimeout: TimeInterval = 30
    let followUpEchoCooldown: TimeInterval = 0.35
}
