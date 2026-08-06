import Foundation

public enum TARSTStatus: Equatable {
    case needsSetup
    case idle
    case awaitingSpeech
    case listening
    case responding
    case paused
    case error(String)

    public var title: String {
        switch self {
        case .needsSetup: "需要设置"
        case .idle: "待命"
        case .awaitingSpeech: "我在听"
        case .listening: "正在倾听"
        case .responding: "正在回应"
        case .paused: "已暂停"
        case .error: "需要注意"
        }
    }

    public var icon: String {
        switch self {
        case .listening, .awaitingSpeech: "ear.fill"
        case .responding: "waveform"
        case .paused: "pause.circle"
        case .error, .needsSetup: "exclamationmark.circle"
        case .idle: "moon.stars"
        }
    }
}

enum SessionMode: Equatable {
    case idle
    case awaitingSpeech(deadline: TimeInterval)
    case listening(startedAt: TimeInterval, lastVoiceAt: TimeInterval)
    case responding
    case paused
}

struct SessionPolicy {
    let speechStartTimeout: TimeInterval = 6
    let turnSilenceTimeout: TimeInterval = 1.8
    let maximumTurnLength: TimeInterval = 45
    let voiceThreshold: Float = 0.5
}
