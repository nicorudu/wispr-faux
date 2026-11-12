import Foundation

/// Rule-based cleanup applied to every transcript before insertion (MVP).
/// LLM formatting via Claude comes later (BUILD_PLAN.md §6).
public struct TextCleaner: Sendable {
    /// User-defined find → replace pairs, e.g. `["whisper faux": "Wispr Faux"]`.
    public var replacements: [String: String]

    public init(replacements: [String: String] = [:]) {
        self.replacements = replacements
    }

    /// Trims surrounding whitespace and applies replacements. Longer keys are applied
    /// first so a phrase wins over a word it contains.
    public func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for key in replacements.keys.sorted(by: { $0.count > $1.count }) {
            guard !key.isEmpty, let value = replacements[key] else { continue }
            text = text.replacingOccurrences(of: key, with: value)
        }
        return text
    }

    /// Whisper tends to produce these on silent or near-silent audio. Only drop a
    /// transcript on this basis when the recording was also quiet, since a user can
    /// genuinely say "Thank you."
    public static func isLikelySilenceArtifact(_ transcript: String) -> Bool {
        let normalized = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty || silenceArtifacts.contains(normalized)
    }

    /// Whisper's descriptions of non-speech, e.g. "[BLANK_AUDIO]", "(silence)", "[Music]".
    /// Never something the user said, so these are always dropped.
    public static func isNonSpeechMarker(_ transcript: String) -> Bool {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first, let last = text.last, text.count >= 2 else { return false }
        return (first == "[" && last == "]") || (first == "(" && last == ")")
    }

    /// Whether text inserted right after `previous` needs a space first, so a second
    /// dictation doesn't run into the end of the first ("…today.Next"). No space at the
    /// start of a line, after whitespace, or after an opening bracket or quote.
    public static func needsLeadingSpace(after previous: Character?) -> Bool {
        guard let previous else { return false }
        if previous.isWhitespace || previous.isNewline { return false }
        return !"([{\"'“‘/-–—".contains(previous)
    }

    static let silenceArtifacts: Set<String> = [
        "[blank_audio]",
        "(silence)",
        "thank you.",
        "thanks for watching!",
        "you",
    ]
}
