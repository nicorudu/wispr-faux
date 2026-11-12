import Foundation
import PostProcessKit

/// Checks a model's cleanup before it's pasted. Cleanup only ever removes words (fillers,
/// repeats, the wrong half of a self-correction) and fixes punctuation, so a reply that
/// brings in new words, grows, or collapses to almost nothing is the model misbehaving:
/// answering a dictated question, following a dictated instruction, rewording or
/// summarizing. Those are rejected and the transcript is pasted as spoken.
public enum CleanupGuard {
    public enum Verdict: Sendable, Equatable {
        case accept(String)
        case reject(Reason)
    }

    public enum Reason: String, Sendable, Equatable {
        case empty = "empty reply"
        case newWords = "added words that weren't spoken"
        case longer = "longer than what was said"
        case tooShort = "dropped most of what was said"
        case extraLines = "added lines"
    }

    /// Words a reply may add: number formatting ("fifteen" → "15") and the like.
    static let allowedNewWords = 2
    /// A reply may keep as little as this share of the words (long self-corrections).
    static let minimumKeptShare = 0.2

    public static func review(original: String, reply: String) -> Verdict {
        let cleaned = sanitize(reply)
        guard !cleaned.isEmpty else { return .reject(.empty) }

        let originalLines = original.split(whereSeparator: \.isNewline).count
        if cleaned.split(whereSeparator: \.isNewline).count > max(originalLines, 1) {
            return .reject(.extraLines)
        }

        let spoken = WordErrorRate.words(original)
        let written = WordErrorRate.words(cleaned)
        guard !written.isEmpty else { return .reject(.empty) }
        if written.count > spoken.count + allowedNewWords { return .reject(.longer) }

        var available = Dictionary(spoken.map { ($0, 1) }, uniquingKeysWith: +)
        var newWords = 0
        for word in written {
            if let count = available[word], count > 0 {
                available[word] = count - 1
            } else {
                newWords += 1
            }
        }
        if newWords > allowedNewWords { return .reject(.newWords) }

        if spoken.count >= 10, Double(written.count) < Double(spoken.count) * minimumKeptShare {
            return .reject(.tooShort)
        }
        return .accept(cleaned)
    }

    /// Strips what models wrap around an answer: reasoning blocks, a label like
    /// "Cleaned text:", surrounding quotes.
    static func sanitize(_ reply: String) -> String {
        var text = reply
        if let thinkEnd = text.range(of: "</think>") {
            text = String(text[thinkEnd.upperBound...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let label = text.range(of: #"^(here(?:'s| is) the cleaned(?: up)? text|cleaned(?: up)?(?: text)?|output|result)\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            text = String(text[label.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let quotes: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'")]
        for (open, close) in quotes where text.count >= 2 && text.first == open && text.last == close {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
