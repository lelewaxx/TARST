import Foundation

public struct ChineseSentenceChunker {
    private var pending = ""
    private let minimumPhraseLength = 12
    public init() {}
    public mutating func append(_ text: String) -> [String] {
        pending += text
        var result: [String] = []
        while let index = pending.firstIndex(where: { "。！？；\n".contains($0) }) {
            let end = pending.index(after: index)
            let sentence = String(pending[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(..<end)
            if !sentence.isEmpty { result.append(sentence) }
        }
        // Voice agents feel faster when TTS starts at a stable natural phrase,
        // not only after a full sentence. Flush the earliest comma/colon whose
        // prefix is long enough to sound intentional; never hard-cut a word.
        while pending.count >= minimumPhraseLength {
            var phraseEnd: String.Index?
            for index in pending.indices where "，、： ".contains(pending[index]) {
                let end = pending.index(after: index)
                if pending[..<end].count >= minimumPhraseLength {
                    phraseEnd = end
                    break
                }
            }
            guard let phraseEnd else { break }
            let sentence = String(pending[..<phraseEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(..<phraseEnd)
            if !sentence.isEmpty { result.append(sentence) }
        }
        return result
    }
    public mutating func finish() -> [String] {
        defer { pending = "" }
        let value = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? [] : [value]
    }
}
