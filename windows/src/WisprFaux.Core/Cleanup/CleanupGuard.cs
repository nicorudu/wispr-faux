using System.Text.RegularExpressions;
using WisprFaux.Core.Text;

namespace WisprFaux.Core.Cleanup;

public enum RejectReason
{
    Empty,
    NewWords,
    Longer,
    TooShort,
    ExtraLines,
}

public static class RejectReasonText
{
    public static string Describe(this RejectReason reason) => reason switch
    {
        RejectReason.Empty => "empty reply",
        RejectReason.NewWords => "added words that weren't spoken",
        RejectReason.Longer => "longer than what was said",
        RejectReason.TooShort => "dropped most of what was said",
        RejectReason.ExtraLines => "added lines",
        _ => reason.ToString(),
    };
}

/// <summary>A guard verdict: either the cleaned text, or why it was rejected.</summary>
public readonly record struct GuardVerdict(string? Accepted, RejectReason? Rejected)
{
    public static GuardVerdict Accept(string text) => new(text, null);
    public static GuardVerdict Reject(RejectReason reason) => new(null, reason);
}

/// <summary>
/// Checks a model's cleanup before it's pasted. Cleanup only ever removes words (fillers,
/// repeats, the wrong half of a self-correction) and fixes punctuation, so a reply that brings in
/// new words, grows, or collapses to almost nothing is the model misbehaving: answering a
/// dictated question, following a dictated instruction, rewording or summarizing. Those are
/// rejected and the transcript is pasted as spoken.
/// </summary>
public static class CleanupGuard
{
    /// <summary>Words a reply may add: number formatting ("fifteen" → "15") and the like.</summary>
    internal const int AllowedNewWords = 2;
    /// <summary>A reply may keep as little as this share of the words (long self-corrections).</summary>
    internal const double MinimumKeptShare = 0.2;

    public static GuardVerdict Review(string original, string reply)
    {
        var cleaned = Sanitize(reply);
        if (cleaned.Length == 0) return GuardVerdict.Reject(RejectReason.Empty);

        var originalLines = Lines(original);
        if (Lines(cleaned) > Math.Max(originalLines, 1)) return GuardVerdict.Reject(RejectReason.ExtraLines);

        var spoken = Words.Of(original);
        var written = Words.Of(cleaned);
        if (written.Count == 0) return GuardVerdict.Reject(RejectReason.Empty);
        if (written.Count > spoken.Count + AllowedNewWords) return GuardVerdict.Reject(RejectReason.Longer);

        var available = new Dictionary<string, int>();
        foreach (var w in spoken) available[w] = available.GetValueOrDefault(w) + 1;
        var newWords = 0;
        foreach (var w in written)
        {
            if (available.TryGetValue(w, out var count) && count > 0) available[w] = count - 1;
            else newWords++;
        }
        if (newWords > AllowedNewWords) return GuardVerdict.Reject(RejectReason.NewWords);

        if (spoken.Count >= 10 && written.Count < spoken.Count * MinimumKeptShare)
            return GuardVerdict.Reject(RejectReason.TooShort);
        return GuardVerdict.Accept(cleaned);
    }

    static int Lines(string text) =>
        text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries).Length;

    static readonly Regex Label = new(
        @"^(here(?:'s| is) the cleaned(?: up)? text|cleaned(?: up)?(?: text)?|output|result)\s*:\s*",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// <summary>
    /// Strips what models wrap around an answer: reasoning blocks, a label like "Cleaned text:",
    /// surrounding quotes.
    /// </summary>
    internal static string Sanitize(string reply)
    {
        var text = reply;
        var thinkEnd = text.IndexOf("</think>", StringComparison.Ordinal);
        if (thinkEnd >= 0) text = text[(thinkEnd + "</think>".Length)..];
        text = text.Trim();
        var label = Label.Match(text);
        if (label.Success) text = text[label.Length..].Trim();
        foreach (var (open, close) in new[] { ('"', '"'), ('“', '”'), ('\'', '\'') })
        {
            if (text.Length >= 2 && text[0] == open && text[^1] == close)
                text = text[1..^1].Trim();
        }
        return text;
    }
}
