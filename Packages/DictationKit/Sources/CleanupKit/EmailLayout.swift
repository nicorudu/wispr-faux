import Foundation

/// Puts a cleaned-up email on its own lines when the model left it as one: the greeting
/// ("Hey Sarah,") on the first line, then the message, then the sign-off ("Thanks."),
/// with a blank line between. Small models punctuate a dictated email reliably but rarely
/// break its lines.
///
/// Only line breaks change (and a comma after the greeting), never words. It needs the
/// shape of a real email, so a quick "Hey, can you grab milk? Thanks." stays on one line:
/// a greeting with a name, a message of two or more sentences, and a sign-off at the end.
enum EmailLayout {
    static func apply(to text: String) -> String {
        guard !text.contains(where: \.isNewline),
              let greeting = text.firstMatch(of: greetingPattern),
              let ending = text.firstMatch(of: signOffPattern),
              greeting.range.upperBound <= ending.range.lowerBound
        else { return text }

        // The message keeps its last punctuation; a comma before the sign-off becomes a period.
        let end = ending.output.1 == "," ? "." : ending.output.1
        let message = text[greeting.range.upperBound..<ending.range.lowerBound].trimmingCharacters(in: .whitespaces) + end
        guard message.filter({ ".!?".contains($0) }).count >= 2 else { return text }

        return "\(greeting.output.1),\n\n\(capitalized(message))\n\n\(capitalized(ending.output.2))"
    }

    private static func capitalized(_ line: some StringProtocol) -> String {
        line.prefix(1).uppercased() + line.dropFirst()
    }

    /// "Hey Sarah," "Hi team." "Dear Dr. Lee:" at the very start, punctuated.
    nonisolated(unsafe) private static let greetingPattern =
        #/^((?i:hey|hi|hello|dear|good (?:morning|afternoon|evening))(?: (?:Mr|Mrs|Ms|Dr)\.)?(?: [\p{L}'’-]+){1,3}?)[,.!:] /#

    /// The last sentence, when it's a sign-off ("Thanks." "Thank you so much!" "Cheers,
    /// Alex."), with the punctuation before it.
    nonisolated(unsafe) private static let signOffPattern =
        #/([.!?,]) +((?i:thanks|thank you|cheers|regards|best regards|kind regards|sincerely|best wishes|all the best|talk soon|take care)\b[^.!?]{0,40}[.!]?)$/#
}
