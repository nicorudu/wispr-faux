using System.Text.RegularExpressions;

namespace WisprFaux.Core.Cleanup;

/// <summary>
/// Spots signs of a stumble in a transcript: fillers, self-corrections, repeated words,
/// broken-off phrases. Cleanup only runs when one is present, so clean dictations are pasted
/// as Whisper wrote them, with no added delay.
/// </summary>
public static class DisfluencyCues
{
    public static bool SuggestCleanup(string text) => Patterns.Any(p => p.IsMatch(text));

    static readonly Regex[] Patterns = new[]
    {
        // Fillers.
        @"\b(u+m+|u+h+|uhm+|erm+|er|hmm+|mm+)\b",
        // Self-corrections and restarts.
        @"\b(i mean|i meant|sorry|no wait|wait|actually|scratch that|strike that|or rather|let me rephrase|never ?mind|correction|no no)\b",
        // A word or two said twice in a row: "the the", "we should, we should".
        @"\b(\w+(?: \w+)?)\b[\s,]+\1\b",
        // Broken-off phrases.
        @"(--|—|\.\.\.|…)",
    }.Select(p => new Regex(p, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled)).ToArray();
}
