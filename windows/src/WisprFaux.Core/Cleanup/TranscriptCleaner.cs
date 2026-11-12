using System.Diagnostics;
using WisprFaux.Core.Text;

namespace WisprFaux.Core.Cleanup;

/// <summary>Something that runs the cleanup prompt: a model on this PC or a cloud API.</summary>
public interface ICleanupEngine
{
    /// <summary>Shown in logs and settings, e.g. "GLM-4.7-Flash (Z.ai)".</summary>
    string Name { get; }

    /// <summary>
    /// Sends the instructions, the worked examples and the transcript, and returns the model's
    /// reply as-is (the guard checks it).
    /// </summary>
    Task<string> CompleteAsync(
        string instructions,
        IReadOnlyList<(string Dictated, string Cleaned)> examples,
        string text,
        int maxTokens,
        CancellationToken cancellationToken);
}

public enum CleanupKind
{
    /// <summary>The model's version was used.</summary>
    Cleaned,
    /// <summary>No sign of a stumble, so the model wasn't asked.</summary>
    Skipped,
    /// <summary>The model's reply failed the guard; the transcript was kept.</summary>
    Rejected,
    /// <summary>No reply in time; the transcript was kept.</summary>
    TimedOut,
    /// <summary>The engine failed (network, model); the transcript was kept.</summary>
    Failed,
}

/// <summary>What happened to one transcript.</summary>
public sealed record CleanupOutcome(string Text, CleanupKind Kind, TimeSpan Duration, RejectReason? Reason = null, string? Error = null)
{
    public bool ChangedText => Kind == CleanupKind.Cleaned;

    public string Describe() => Kind switch
    {
        CleanupKind.Cleaned => "cleaned",
        CleanupKind.Skipped => "no stumble, skipped",
        CleanupKind.Rejected => $"kept as spoken ({Reason?.Describe()})",
        CleanupKind.TimedOut => "kept as spoken (too slow)",
        CleanupKind.Failed => $"kept as spoken ({Error})",
        _ => Kind.ToString(),
    };
}

/// <summary>
/// Runs a transcript through an engine, but only when it shows a stumble, within a time limit,
/// and through <see cref="CleanupGuard"/>. Whatever goes wrong, the transcript comes back
/// unchanged, so cleanup can never lose or garble a dictation.
/// </summary>
public sealed class TranscriptCleaner
{
    public ICleanupEngine Engine { get; }
    public TimeSpan Timeout { get; init; }
    /// <summary>Ask the model even when no stumble is spotted (for the Test button).</summary>
    public bool AlwaysRun { get; init; }

    public TranscriptCleaner(ICleanupEngine engine, TimeSpan? timeout = null)
    {
        Engine = engine;
        Timeout = timeout ?? TimeSpan.FromSeconds(3);
    }

    public async Task<CleanupOutcome> CleanAsync(string transcript, CancellationToken cancellationToken = default)
    {
        var watch = Stopwatch.StartNew();
        CleanupOutcome Outcome(string text, CleanupKind kind, RejectReason? reason = null, string? error = null) =>
            new(text, kind, watch.Elapsed, reason, error);

        if (!AlwaysRun && !DisfluencyCues.SuggestCleanup(transcript))
            return Outcome(transcript, CleanupKind.Skipped);

        // Cleanup only shortens text: room for the whole transcript, plus punctuation.
        var maxTokens = Words.Count(transcript) * 2 + 32;

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(Timeout);
        var work = Engine.CompleteAsync(CleanupPrompt.Instructions, CleanupPrompt.Examples, transcript, maxTokens, timeout.Token);
        var finished = await Task.WhenAny(work, Task.Delay(Timeout, cancellationToken)).ConfigureAwait(false);

        if (finished != work)
        {
            timeout.Cancel();
            _ = work.ContinueWith(t => _ = t.Exception, TaskScheduler.Default); // Observe a late failure.
            return Outcome(transcript, CleanupKind.TimedOut);
        }

        string reply;
        try
        {
            reply = await work.ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return Outcome(transcript, CleanupKind.TimedOut);
        }
        catch (Exception e)
        {
            return Outcome(transcript, CleanupKind.Failed, error: e.Message);
        }

        var verdict = CleanupGuard.Review(transcript, reply);
        return verdict.Accepted is { } cleaned
            ? Outcome(cleaned, CleanupKind.Cleaned)
            : Outcome(transcript, CleanupKind.Rejected, verdict.Rejected);
    }
}
