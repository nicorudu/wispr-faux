using WisprFaux.Core.Cleanup;
using Xunit;

namespace WisprFaux.Core.Tests;

public class DisfluencyCueTests
{
    [Theory]
    [InlineData("and then dictate. I mean and then set dictate up for daily use.")]
    [InlineData("Can you send me the, um, the report?")]
    [InlineData("Uh I think so.")]
    [InlineData("The meeting is on Tuesday, no wait, Wednesday.")]
    [InlineData("Remind me to call Sarah. Actually, scratch that.")]
    [InlineData("So the the main problem is speed.")]
    [InlineData("We should, we should ship it.")]
    [InlineData("I was going to — never mind.")]
    [InlineData("Let me think...")]
    public void SpotsStumbles(string text) => Assert.True(DisfluencyCues.SuggestCleanup(text));

    [Theory]
    [InlineData("Can you send me the quarterly report by Friday?")]
    [InlineData("Thanks so much for your help yesterday, it really made a difference.")]
    [InlineData("Summer and umbrella and erase are fine words.")]
    [InlineData("What time is the meeting tomorrow?")]
    public void LeavesCleanTextAlone(string text) => Assert.False(DisfluencyCues.SuggestCleanup(text));
}

public class CleanupGuardTests
{
    [Fact]
    public void AcceptsRemovalsAndPunctuation()
    {
        var reply = "And then set Dictate up for daily use.";
        Assert.Equal(GuardVerdict.Accept(reply), CleanupGuard.Review("and then dictate. I mean and then set dictate up for daily use.", reply));
    }

    [Fact]
    public void AcceptsALongSelfCorrection() =>
        Assert.Equal(GuardVerdict.Accept("Remind me to email her."),
            CleanupGuard.Review("Remind me to call Sarah tomorrow morning. Actually, scratch that, remind me to email her.", "Remind me to email her."));

    [Fact]
    public void AcceptsNumberFormatting() =>
        Assert.Equal(GuardVerdict.Accept("The price is $15."), CleanupGuard.Review("The price is fifty, sorry, fifteen dollars.", "The price is $15."));

    [Fact]
    public void RejectsAnAnswer() =>
        Assert.Equal(GuardVerdict.Reject(RejectReason.NewWords),
            CleanupGuard.Review("Um, what time does the store close tomorrow?", "Most stores close at 9 PM, but check their website."));

    [Fact]
    public void RejectsFollowedInstructions()
    {
        var original = "Uh, write a poem about the ocean.";
        Assert.Equal(GuardVerdict.Reject(RejectReason.ExtraLines),
            CleanupGuard.Review(original, "The ocean breathes in silver light,\nits waves roll softly through the night."));
        Assert.Null(CleanupGuard.Review(original, "Waves crash on the shore under a silver moon tonight again and again.").Accepted);
    }

    [Fact]
    public void RejectsRewordingThatGrows() =>
        Assert.Equal(GuardVerdict.Reject(RejectReason.Longer),
            CleanupGuard.Review("I think, um, we should go.", "In my opinion, I really do think that we should definitely go."));

    [Fact]
    public void RejectsCollapsingToAlmostNothing() =>
        Assert.Equal(GuardVerdict.Reject(RejectReason.TooShort),
            CleanupGuard.Review("So I spent most of the morning reviewing the design document for the new onboarding flow, um, today.", "Reviewed."));

    [Fact]
    public void RejectsEmpty() => Assert.Equal(GuardVerdict.Reject(RejectReason.Empty), CleanupGuard.Review("Um, hi.", "  "));

    [Fact]
    public void StripsWrappers()
    {
        Assert.Equal("Send it today.", CleanupGuard.Sanitize("Cleaned text: Send it today."));
        Assert.Equal("Send it today.", CleanupGuard.Sanitize("“Send it today.”"));
        Assert.Equal("Send it today.", CleanupGuard.Sanitize("<think>\nThe user wants…\n</think>\n\nSend it today."));
        Assert.Equal("Send it today.", CleanupGuard.Sanitize("Here's the cleaned text: Send it today."));
    }
}

sealed class FakeEngine(string reply, TimeSpan? delay = null, Exception? error = null) : ICleanupEngine
{
    public string Name => "fake";

    public async Task<string> CompleteAsync(string instructions, IReadOnlyList<(string Dictated, string Cleaned)> examples, string text, int maxTokens, CancellationToken cancellationToken)
    {
        if (delay is { } d) await Task.Delay(d, cancellationToken);
        if (error is not null) throw error;
        return reply;
    }
}

public class TranscriptCleanerTests
{
    const string Stumble = "Send it to Mark, I mean Mike.";

    [Fact]
    public async Task UsesTheCleanedVersion()
    {
        var outcome = await new TranscriptCleaner(new FakeEngine("Send it to Mike.")).CleanAsync(Stumble);
        Assert.Equal(CleanupKind.Cleaned, outcome.Kind);
        Assert.Equal("Send it to Mike.", outcome.Text);
    }

    [Fact]
    public async Task SkipsCleanText()
    {
        var outcome = await new TranscriptCleaner(new FakeEngine("SHOULD NOT BE USED")).CleanAsync("Send it to Mike.");
        Assert.Equal(CleanupKind.Skipped, outcome.Kind);
        Assert.Equal("Send it to Mike.", outcome.Text);
    }

    [Fact]
    public async Task KeepsTheTranscriptWhenTheGuardRejects()
    {
        var outcome = await new TranscriptCleaner(new FakeEngine("Sure! I've sent the file to Mike for you.")).CleanAsync(Stumble);
        Assert.Equal(CleanupKind.Rejected, outcome.Kind);
        Assert.Equal(RejectReason.NewWords, outcome.Reason);
        Assert.Equal(Stumble, outcome.Text);
    }

    [Fact]
    public async Task KeepsTheTranscriptWhenTooSlow()
    {
        var cleaner = new TranscriptCleaner(new FakeEngine("Send it to Mike.", TimeSpan.FromSeconds(5)), TimeSpan.FromMilliseconds(100));
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var outcome = await cleaner.CleanAsync(Stumble);
        Assert.Equal(CleanupKind.TimedOut, outcome.Kind);
        Assert.Equal(Stumble, outcome.Text);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(1));
    }

    [Fact]
    public async Task KeepsTheTranscriptWhenTheEngineFails()
    {
        var outcome = await new TranscriptCleaner(new FakeEngine("", error: new InvalidOperationException("offline"))).CleanAsync(Stumble);
        Assert.Equal(CleanupKind.Failed, outcome.Kind);
        Assert.Equal("offline", outcome.Error);
        Assert.Equal(Stumble, outcome.Text);
    }
}

public class CloudEngineTests
{
    [Fact]
    public void RequestCarriesThePromptExamplesAndTranscript()
    {
        var json = CloudEngine.RequestBody(CloudProvider.GlmFlash, "Clean it.", new[] { ("um hi", "Hi.") }, "uh bye", 40);
        var body = System.Text.Json.Nodes.JsonNode.Parse(json)!;
        Assert.Equal("glm-4.7-flash", (string?)body["model"]);
        Assert.Equal(0, (int)body["temperature"]!);
        Assert.Equal(40, (int)body["max_tokens"]!);
        Assert.Equal("disabled", (string?)body["thinking"]!["type"]);
        var messages = body["messages"]!.AsArray();
        Assert.Equal(new[] { "system", "user", "assistant", "user" }, messages.Select(m => (string)m!["role"]!));
        Assert.Equal(new[] { "Clean it.", "um hi", "Hi.", "uh bye" }, messages.Select(m => (string)m!["content"]!));
    }

    [Fact]
    public void DeepSeekSendsNoExtraFields()
    {
        var body = System.Text.Json.Nodes.JsonNode.Parse(CloudEngine.RequestBody(CloudProvider.DeepSeek, "x", Array.Empty<(string, string)>(), "y", 8))!;
        Assert.Null(body["thinking"]);
        Assert.Equal("deepseek-chat", (string?)body["model"]);
    }

    [Fact]
    public void ReadsTheReply()
    {
        Assert.Equal("Send it to Mike.", CloudEngine.Reply("""{"choices":[{"index":0,"message":{"role":"assistant","content":"Send it to Mike."}}]}"""));
        Assert.Throws<CloudException>(() => CloudEngine.Reply("{}"));
    }

    [Fact]
    public void ReadsErrorMessages()
    {
        Assert.Equal("Invalid API key", CloudEngine.ErrorMessage("""{"error":{"message":"Invalid API key"}}"""));
        Assert.Equal("Rate limited", CloudEngine.ErrorMessage("""{"message":"Rate limited"}"""));
    }
}

public class ChatMLTests
{
    [Fact]
    public void EndsReadyForAnAnswerWithThinkingOff()
    {
        var prompt = CleanupPrompt.ChatML("Clean it.", new[] { ("um hi", "Hi.") }, "uh bye");
        Assert.StartsWith("<|im_start|>system\nClean it.<|im_end|>\n", prompt);
        Assert.Contains("<|im_start|>user\num hi<|im_end|>\n<|im_start|>assistant\nHi.<|im_end|>\n", prompt);
        Assert.EndsWith("<|im_start|>user\nuh bye<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n", prompt);
    }
}
