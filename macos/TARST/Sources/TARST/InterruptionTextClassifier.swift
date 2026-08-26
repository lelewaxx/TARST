import Foundation

public enum InterruptionTextClassification: Equatable {
    case echo
    case user
    case suspectedUser
    case undetermined
}

public enum InterruptionTextClassifier {
    private static let interruptionPhrases = [
        "停一下", "停下", "等等", "等一下", "别说了", "不要说了", "打住",
        "好了", "可以了", "行了", "闭嘴", "tarst"
    ]

    public static func classify(candidate: String, spokenResponse: String) -> InterruptionTextClassification {
        let candidate = normalize(candidate)
        let response = normalize(spokenResponse)
        guard !candidate.isEmpty else { return .undetermined }
        guard candidate.count >= 4, !response.isEmpty else { return .undetermined }
        if response.contains(candidate) { return .echo }

        let grams = bigrams(candidate)
        guard !grams.isEmpty else { return .undetermined }
        let responseGrams = Set(bigrams(response))
        let overlap = Double(grams.filter(responseGrams.contains).count) / Double(grams.count)
        // Echo ASR can substitute isolated Chinese characters. Bigrams are
        // brittle under those substitutions, so also compare ordered character
        // similarity. Genuine user speech appended after echo will eventually
        // lower both ratios and still needs progressive evidence to interrupt.
        let orderedOverlap = Double(longestCommonSubsequenceLength(candidate, response)) /
            Double(candidate.count)
        if overlap >= 0.45 || orderedOverlap >= 0.72 { return .echo }
        if interruptionPhrases.contains(where: candidate.contains) { return .user }
        return .user
    }

    static func normalize(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || ($0.value >= 0x4E00 && $0.value <= 0x9FFF)
        }.map(Character.init))
    }


    static func containsInterruptionPhrase(_ value: String) -> Bool {
        let value = normalize(value)
        return interruptionPhrases.contains(where: value.contains)
    }

    /// Removes the longest leading span that can be explained by any contiguous
    /// portion of the answer TARST is currently speaking. Streaming ASR results
    /// are cumulative, so a real interruption commonly appears as
    /// `long speaker echo + new user suffix`.
    static func unexplainedSuffix(candidate: String, spokenResponse: String) -> String {
        let candidate = normalize(candidate)
        let response = normalize(spokenResponse)
        guard candidate.count >= 4, !response.isEmpty else { return candidate }
        let characters = Array(candidate)
        for length in stride(from: characters.count, through: 4, by: -1) {
            let prefix = String(characters.prefix(length))
            if response.contains(prefix) {
                return String(characters.dropFirst(length))
            }
        }
        return candidate
    }

    private static func bigrams(_ value: String) -> [String] {
        let characters = Array(value)
        guard characters.count >= 2 else { return [] }
        return (0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) }
    }

    private static func longestCommonSubsequenceLength(_ left: String, _ right: String) -> Int {
        let left = Array(left.suffix(160))
        let right = Array(right.suffix(320))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: right.count + 1)
        for leftCharacter in left {
            var current = [Int](repeating: 0, count: right.count + 1)
            for (index, rightCharacter) in right.enumerated() {
                current[index + 1] = leftCharacter == rightCharacter
                    ? previous[index] + 1
                    : max(previous[index + 1], current[index])
            }
            previous = current
        }
        return previous[right.count]
    }
}


/// Stateful evidence tracker for one playback probe. It avoids classifying a
/// cumulative ASR transcript solely by its dominant echo prefix, while still
/// requiring progressive evidence before an ordinary recognition mismatch can
/// stop playback.
public struct InterruptionProbeTracker {
    private var lastDivergentSuffix = ""
    private var progressiveEvidence = 0

    public init() {}

    public mutating func reset() {
        lastDivergentSuffix = ""
        progressiveEvidence = 0
    }

    public mutating func observe(
        candidate: String,
        spokenResponse: String
    ) -> InterruptionTextClassification {
        let suffix = InterruptionTextClassifier.unexplainedSuffix(
            candidate: candidate,
            spokenResponse: spokenResponse
        )
        let normalizedCandidate = InterruptionTextClassifier.normalize(candidate)
        let hasExactEchoAnchor = suffix != normalizedCandidate
        if suffix.isEmpty {
            reset()
            return .echo
        }
        // If no exact echo prefix can be separated, retain the fuzzy whole-text
        // classifier for ordinary ASR variations of the loudspeaker output.
        if suffix == normalizedCandidate {
            let whole = InterruptionTextClassifier.classify(
                candidate: candidate,
                spokenResponse: spokenResponse
            )
            if whole == .echo {
                reset()
                return .echo
            }
        }
        if InterruptionTextClassifier.containsInterruptionPhrase(suffix),
           hasExactEchoAnchor || normalizedCandidate.count <= 8 {
            return .user
        }
        guard suffix.count >= 4 else { return .undetermined }

        let suffixClassification = InterruptionTextClassifier.classify(
            candidate: suffix,
            spokenResponse: spokenResponse
        )
        guard suffixClassification == .user else {
            reset()
            return suffixClassification
        }

        if !lastDivergentSuffix.isEmpty,
           suffix != lastDivergentSuffix,
           (suffix.hasPrefix(lastDivergentSuffix) || lastDivergentSuffix.hasPrefix(suffix)) {
            progressiveEvidence += 1
        } else if suffix != lastDivergentSuffix {
            progressiveEvidence = 1
        }
        lastDivergentSuffix = suffix

        // A probe with an exact echo anchor has strong evidence that only its
        // suffix came from the user. An entirely unanchored transcript is much
        // noisier: early loudspeaker ASR partials can briefly look unrelated
        // before converging back to the spoken answer. Require a longer phrase
        // and one additional progressive revision in that case.
        let requiredEvidence = hasExactEchoAnchor ? 2 : 4
        let hasEnoughText = hasExactEchoAnchor || suffix.count >= 18
        if hasEnoughText && progressiveEvidence >= requiredEvidence { return .user }
        let hasPauseEvidence = hasExactEchoAnchor
            ? progressiveEvidence >= 1
            : suffix.count >= 12 && progressiveEvidence >= 2
        return hasPauseEvidence ? .suspectedUser : .undetermined
    }
}
