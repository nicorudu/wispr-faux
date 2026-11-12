using System.Globalization;
using System.Text;

namespace WisprFaux.Core.Text;

/// <summary>Splits text into comparable words, as the Mac app's <c>WordErrorRate.words</c> does.</summary>
public static class Words
{
    /// <summary>Lowercase words with punctuation stripped (inner apostrophes kept).</summary>
    public static List<string> Of(string text)
    {
        var result = new List<string>();
        foreach (var raw in text.ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            var kept = new StringBuilder(raw.Length);
            foreach (var c in raw)
            {
                if (char.IsLetterOrDigit(c) || CharUnicodeInfo.GetUnicodeCategory(c) is UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark)
                    kept.Append(c);
                else if (c is '\'' or '’')
                    kept.Append('\'');
            }
            var word = kept.ToString().Trim('\'');
            if (word.Length > 0) result.Add(word);
        }
        return result;
    }

    public static int Count(string text) =>
        text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
}
