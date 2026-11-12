using WisprFaux.Core.Audio;
using WisprFaux.Core.History;
using WisprFaux.Core.Settings;
using WisprFaux.Core.Text;
using Xunit;

namespace WisprFaux.Core.Tests;

public class TextCleanerTests
{
    [Fact]
    public void TrimsSurroundingWhitespace() => Assert.Equal("hello world", TextCleaner.Clean("  hello world \n"));

    [Theory]
    [InlineData("")]
    [InlineData("  ")]
    [InlineData("Thank you.")]
    [InlineData(" you ")]
    [InlineData("[BLANK_AUDIO]")]
    public void SilenceArtifacts(string transcript) => Assert.True(TextCleaner.IsLikelySilenceArtifact(transcript));

    [Fact]
    public void KeepsRealSpeech() => Assert.False(TextCleaner.IsLikelySilenceArtifact("Thank you for the update."));

    [Fact]
    public void NonSpeechMarkers()
    {
        Assert.True(TextCleaner.IsNonSpeechMarker("[BLANK_AUDIO]"));
        Assert.True(TextCleaner.IsNonSpeechMarker(" (silence) "));
        Assert.True(TextCleaner.IsNonSpeechMarker("[Music]"));
        Assert.False(TextCleaner.IsNonSpeechMarker("Call me (maybe) later."));
        Assert.False(TextCleaner.IsNonSpeechMarker("Thank you."));
        Assert.False(TextCleaner.IsNonSpeechMarker(""));
    }

    [Fact]
    public void LeadingSpace()
    {
        Assert.True(TextCleaner.NeedsLeadingSpace('.'));
        Assert.True(TextCleaner.NeedsLeadingSpace('d'));
        Assert.True(TextCleaner.NeedsLeadingSpace(','));
        Assert.False(TextCleaner.NeedsLeadingSpace(null));
        Assert.False(TextCleaner.NeedsLeadingSpace(' '));
        Assert.False(TextCleaner.NeedsLeadingSpace('\n'));
        Assert.False(TextCleaner.NeedsLeadingSpace('('));
        Assert.False(TextCleaner.NeedsLeadingSpace('“'));
    }

    [Fact]
    public void WordsIgnoreCaseAndPunctuation() =>
        Assert.Equal(new[] { "don't", "stop", "café" }, Words.Of("Don’t STOP, café!"));
}

public class SpeechGateTests
{
    [Fact]
    public void ShortTapsAndSilenceAreSkipped()
    {
        var loud = LevelStats.Of(Enumerable.Range(0, 16000).Select(i => 0.3f * MathF.Sin(i * 0.1f)).ToArray());
        var silent = LevelStats.Of(new float[16000]);
        Assert.Equal(GateVerdict.TooShort, SpeechGate.Default.Verdict(TimeSpan.FromMilliseconds(100), loud));
        Assert.Equal(GateVerdict.TooQuiet, SpeechGate.Default.Verdict(TimeSpan.FromSeconds(1), silent));
        Assert.Equal(GateVerdict.Speech, SpeechGate.Default.Verdict(TimeSpan.FromSeconds(1), loud));
    }

    [Fact]
    public void LoudestWindowFindsABriefWord()
    {
        var samples = new float[16000];
        for (var i = 8160; i < 8640; i++) samples[i] = 0.1f; // Exactly one 30 ms window.
        var stats = LevelStats.Of(samples);
        Assert.InRange(stats.LoudestWindowDbfs, -21f, -19f);
        Assert.True(stats.Rms < stats.LoudestWindowRms);
    }
}

public class HistoryStoreTests
{
    static string TempFile() => Path.Combine(Path.GetTempPath(), $"wf-history-{Guid.NewGuid():N}.json");

    [Fact]
    public void KeepsNewestFirstWithinCapacityAndSurvivesARestart()
    {
        var file = TempFile();
        var store = new HistoryStore(file, capacity: 2);
        store.Add(new TranscriptRecord("one", DateTimeOffset.Now));
        store.Add(new TranscriptRecord("two", DateTimeOffset.Now));
        store.Add(new TranscriptRecord("café ✓", DateTimeOffset.Now, "Notepad", "um café"));
        Assert.Equal(new[] { "café ✓", "two" }, store.All.Select(r => r.Text));

        var reopened = new HistoryStore(file, capacity: 1);
        Assert.Equal("Notepad", reopened.Latest?.AppName);
        Assert.Single(reopened.All);
        File.Delete(file);
    }

    [Fact]
    public void AnUnreadableFileStartsEmpty()
    {
        var file = TempFile();
        File.WriteAllText(file, "not json");
        Assert.Empty(new HistoryStore(file).All);
        File.Delete(file);
    }
}

public class SettingsTests
{
    [Fact]
    public void RoundTrips()
    {
        var file = Path.Combine(Path.GetTempPath(), $"wf-settings-{Guid.NewGuid():N}.json");
        var settings = new AppSettings { Cleanup = CleanupMode.Cloud, Language = "es" };
        settings.Triggers = new() { Core.Hotkey.HotkeyTrigger.RightAlt };
        settings.Save(file);
        var loaded = AppSettings.Load(file);
        Assert.Equal(CleanupMode.Cloud, loaded.Cleanup);
        Assert.Equal("es", loaded.Language);
        Assert.Equal(new[] { Core.Hotkey.HotkeyTrigger.RightAlt }, loaded.Triggers);
        Assert.Contains("\"RightAlt\"", File.ReadAllText(file));
        File.Delete(file);
    }

    [Fact]
    public void DefaultsMatchTheMacApp()
    {
        var s = new AppSettings();
        Assert.Equal(ModelCatalog.TurboQ5.Id, s.WhisperModel);
        Assert.Equal(500, s.ClipboardRestoreDelayMs);
        Assert.Null(s.Cleanup);
    }
}
