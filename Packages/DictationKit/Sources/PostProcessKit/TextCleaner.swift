import Foundation

/// Rule-based cleanup applied to every transcript before insertion (MVP).
/// LLM formatting via Claude comes later (BUILD_PLAN.md §6).
public struct TextCleaner: Sendable {
    /// User-defined find → replace pairs, e.g. `["dictate app": "Dictate"]`.
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

    static let silenceArtifacts: Set<String> = [
        "[blank_audio]",
        "(silence)",
        "thank you.",
        "thanks for watching!",
        "you",
    ]
}
