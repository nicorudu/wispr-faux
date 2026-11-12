import Foundation

/// Spots dictations that read as a list or an email, so cleanup can lay them out (numbered
/// lines; greeting, body and sign-off on their own lines) even when nothing was stumbled.
public enum FormattingCues {
    public static func suggestFormatting(_ text: String) -> Bool {
        looksLikeList(text) || looksLikeEmail(text)
    }

    /// "first… second…", "number one… number two…", or a count of things: "three things",
    /// "two main reasons".
    static func looksLikeList(_ text: String) -> Bool {
        listPatterns.contains { matches($0, text) }
    }

    /// Opens with a greeting ("Hey Sarah") and ends with a sign-off ("thanks", "cheers"),
    /// perhaps followed by a name.
    static func looksLikeEmail(_ text: String) -> Bool {
        matches(greeting, text) && matches(signOff, text)
    }

    private static let listPatterns: [NSRegularExpression] = [
        #"\b(first|firstly|number one)\b.*\b(second|secondly|number two)\b"#,
        #"\b(two|three|four|five|six|seven|eight|nine|ten|[2-9]|10) (\w+ )?(things|items|steps|points|reasons|ideas|options|questions|tasks|priorities|goals|changes|issues|updates|takeaways)\b"#,
    ].map(regex)

    private static let greeting = regex(#"^\W*(hey|hi|hello|dear|good (morning|afternoon|evening))\b"#)
    private static let signOff = regex(#"\b(thanks|thank you|cheers|regards|sincerely|best wishes|all the best|talk soon|take care)\b(\W+\w+){0,3}\W*$"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
