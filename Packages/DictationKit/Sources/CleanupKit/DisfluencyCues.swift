import Foundation

/// Spots signs of a stumble in a transcript: fillers, self-corrections, repeated words,
/// broken-off phrases. Cleanup only runs when one is present, so clean dictations are
/// pasted as Whisper wrote them, with no added delay.
public enum DisfluencyCues {
    public static func suggestCleanup(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    private static let patterns: [NSRegularExpression] = [
        // Fillers.
        #"\b(u+m+|u+h+|uhm+|erm+|er|hmm+|mm+)\b"#,
        // Self-corrections and restarts.
        #"\b(i mean|i meant|sorry|no wait|wait|actually|scratch that|strike that|or rather|let me rephrase|never ?mind|correction|no no|don['’]?t say|do not say)\b"#,
        // "Three pizzas, make that four."
        #"[,.] make (that|it)\b"#,
        // A word or two said twice in a row: "the the", "we should, we should".
        #"\b(\w+(?: \w+)?)\b[\s,]+\1\b"#,
        // Broken-off phrases.
        #"(--|—|\.\.\.|…)"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
}
