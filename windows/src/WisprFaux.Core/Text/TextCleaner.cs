namespace WisprFaux.Core.Text;

/// <summary>Rule-based tidying applied to every transcript before it's pasted.</summary>
public static class TextCleaner
{
    /// <summary>Trims surrounding whitespace.</summary>
    public static string Clean(string raw) => raw.Trim();

    /// <summary>
    /// Whisper tends to produce these on silent or near-silent audio. Only drop a transcript on
    /// this basis when the recording was also quiet, since someone can genuinely say "Thank you."
    /// </summary>
    public static bool IsLikelySilenceArtifact(string transcript)
    {
        var normalized = transcript.Trim().ToLowerInvariant();
        return normalized.Length == 0 || SilenceArtifacts.Contains(normalized);
    }

    /// <summary>Whisper's descriptions of non-speech, e.g. "[BLANK_AUDIO]", "(silence)", "[Music]".</summary>
    public static bool IsNonSpeechMarker(string transcript)
    {
        var text = transcript.Trim();
        if (text.Length < 2) return false;
        return (text[0] == '[' && text[^1] == ']') || (text[0] == '(' && text[^1] == ')');
    }

    /// <summary>
    /// Whether text inserted right after <paramref name="previous"/> needs a space first, so a
    /// second dictation doesn't run into the end of the first ("…today.Next").
    /// </summary>
    public static bool NeedsLeadingSpace(char? previous)
    {
        if (previous is not { } c) return false;
        if (char.IsWhiteSpace(c)) return false;
        return !"([{\"'“‘/-–—".Contains(c);
    }

    static readonly HashSet<string> SilenceArtifacts = new()
    {
        "[blank_audio]",
        "(silence)",
        "thank you.",
        "thanks for watching!",
        "you",
    };
}
