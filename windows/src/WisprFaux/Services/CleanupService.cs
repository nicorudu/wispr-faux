using System.Diagnostics;
using WisprFaux.Core.Cleanup;
using WisprFaux.Core.Settings;
using WisprFaux.Platform;

namespace WisprFaux.Services;

/// <summary>
/// Fixes stumbles in transcripts ("um", "Tuesday, no wait, Wednesday", "Mark, I mean Mike") with
/// a small model on this PC or a cloud model the user picks. Only runs when a transcript shows a
/// stumble, and any failure leaves the transcript as spoken.
/// </summary>
sealed class CleanupService : IDisposable
{
    public enum LocalPhase { NotDownloaded, Downloading, Loading, Ready, Failed }

    /// <summary>Slower than this and the transcript is pasted as spoken. Longer than the Mac's 3 s:
    /// a PC without a GPU runs the model on the CPU.</summary>
    static readonly TimeSpan LocalTimeout = TimeSpan.FromSeconds(5);
    static readonly TimeSpan CloudTimeout = TimeSpan.FromSeconds(4);

    readonly AppSettings _settings;
    LocalCleanupEngine _local;

    public ModelFile LocalModel => ModelCatalog.CleanupQwen3;
    public LocalPhase LocalStatus { get; private set; }
    public string? LocalError { get; private set; }
    public double DownloadFraction { get; private set; }
    public string? TestResult { get; private set; }
    public bool IsTesting { get; private set; }
    public event Action? Changed;

    public CleanupService(AppSettings settings)
    {
        _settings = settings;
        _local = new LocalCleanupEngine(LocalModel, settings.UseGpu);
        LocalStatus = LocalModel.IsDownloaded ? LocalPhase.Loading : LocalPhase.NotDownloaded;
        // On this PC by default once its model is there.
        _settings.Cleanup ??= LocalModel.IsDownloaded ? CleanupMode.OnDevice : CleanupMode.Off;
    }

    public CleanupMode Mode => _settings.Cleanup ?? CleanupMode.Off;
    public CloudProvider Provider => CloudProvider.Named(_settings.CloudProvider) ?? CloudProvider.GlmFlash;
    public bool HasCloudKey => SecretStore.Read(Provider.Id) is not null;

    public void Start()
    {
        if (Mode == CleanupMode.OnDevice) LoadLocalModel();
    }

    void Notify() => Changed?.Invoke();

    public void SetMode(CleanupMode mode)
    {
        _settings.Cleanup = mode;
        _settings.Save();
        TestResult = null;
        Log.Info("Cleanup", $"Cleanup mode: {mode}");
        if (mode == CleanupMode.OnDevice) LoadLocalModel();
        Notify();
    }

    public void SetProvider(CloudProvider provider)
    {
        _settings.CloudProvider = provider.Id;
        _settings.Save();
        TestResult = null;
        Notify();
    }

    /// <summary>Stores the provider's API key (encrypted); an empty string removes it.</summary>
    public void SaveCloudKey(string key)
    {
        SecretStore.Save(Provider.Id, key.Trim());
        TestResult = null;
        Notify();
    }

    public async Task DownloadLocalModelAsync()
    {
        if (LocalStatus is not (LocalPhase.NotDownloaded or LocalPhase.Failed)) return;
        LocalStatus = LocalPhase.Downloading;
        DownloadFraction = 0;
        Notify();
        try
        {
            await ModelDownloader.DownloadAsync(LocalModel, new Progress<double>(f =>
            {
                DownloadFraction = f;
                Notify();
            }));
            LoadLocalModel();
        }
        catch (Exception e)
        {
            Log.Error("Cleanup", "Download failed: " + e.Message);
            LocalStatus = LocalPhase.Failed;
            LocalError = "Download failed: " + e.Message;
            Notify();
        }
    }

    void LoadLocalModel()
    {
        if (!LocalModel.IsDownloaded)
        {
            LocalStatus = LocalPhase.NotDownloaded;
            Notify();
            return;
        }
        if (LocalStatus == LocalPhase.Ready) return;
        LocalStatus = LocalPhase.Loading;
        Notify();
        _ = Task.Run(async () =>
        {
            try
            {
                var loadTime = await _local.LoadAsync();
                LocalStatus = LocalPhase.Ready;
                Log.Info("Cleanup", $"Loaded {LocalModel.FileName} in {loadTime.TotalMilliseconds:0} ms");
            }
            catch (Exception e)
            {
                LocalStatus = LocalPhase.Failed;
                LocalError = "Couldn't load the cleanup model: " + e.Message;
                Log.Error("Cleanup", "Couldn't load the cleanup model: " + e);
            }
            Notify();
        });
    }

    /// <summary>The cleaner for the current mode, or null when cleanup is off or not set up.</summary>
    TranscriptCleaner? Cleaner(TimeSpan? timeout = null)
    {
        switch (Mode)
        {
            case CleanupMode.OnDevice:
                if (!LocalModel.IsDownloaded) return null;
                return new TranscriptCleaner(_local, timeout ?? LocalTimeout);
            case CleanupMode.Cloud:
                var key = SecretStore.Read(Provider.Id);
                if (key is null) return null;
                return new TranscriptCleaner(new CloudEngine(Provider, key), timeout ?? CloudTimeout);
            default:
                return null;
        }
    }

    /// <summary>Cleans the transcript, or returns null when cleanup is off or not set up.</summary>
    public async Task<CleanupOutcome?> CleanAsync(string transcript, CancellationToken cancellationToken)
    {
        var cleaner = Cleaner();
        if (cleaner is null) return null;
        var outcome = await cleaner.CleanAsync(transcript, cancellationToken);
        // Lengths and timings only, never the words.
        Log.Info("Cleanup", $"{cleaner.Engine.Name}: {outcome.Describe()} in {outcome.Duration.TotalMilliseconds:0} ms, {transcript.Length} → {outcome.Text.Length} characters");
        return outcome;
    }

    /// <summary>Cleans a sample stumble so the user can see the engine work (and how fast).</summary>
    public async Task TestAsync()
    {
        if (IsTesting) return;
        var cleaner = Cleaner(TimeSpan.FromSeconds(30));
        if (cleaner is null)
        {
            TestResult = Mode switch
            {
                CleanupMode.Cloud => "Add an API key first",
                CleanupMode.OnDevice => "Download the model first",
                _ => "Cleanup is off",
            };
            Notify();
            return;
        }
        IsTesting = true;
        TestResult = "Testing…";
        Notify();
        try
        {
            var sample = new TranscriptCleaner(cleaner.Engine, cleaner.Timeout) { AlwaysRun = true };
            var outcome = await sample.CleanAsync("Um, can you send it to Mark, I mean Mike, by Friday?");
            TestResult = outcome.Kind == CleanupKind.Cleaned
                ? $"{outcome.Duration.TotalSeconds:0.00} s: “{outcome.Text}”"
                : $"{outcome.Duration.TotalSeconds:0.00} s: {outcome.Describe()}";
        }
        finally
        {
            IsTesting = false;
            Notify();
        }
    }

    public string? StatusLine => Mode switch
    {
        CleanupMode.OnDevice => LocalStatus switch
        {
            LocalPhase.NotDownloaded => $"{LocalModel.DisplayName} isn't downloaded",
            LocalPhase.Downloading => $"Downloading {LocalModel.DisplayName}… {DownloadFraction:P0}",
            LocalPhase.Loading => $"Loading {LocalModel.DisplayName}…",
            LocalPhase.Ready => $"{LocalModel.DisplayName}, on this PC",
            LocalPhase.Failed => LocalError,
            _ => null,
        },
        CleanupMode.Cloud => HasCloudKey
            ? $"{Provider.DisplayName}. Dictated text with stumbles is sent to it"
            : $"Add a {Provider.DisplayName} API key",
        _ => null,
    };

    public void OpenKeysPage() => Process.Start(new ProcessStartInfo(Provider.KeysUrl) { UseShellExecute = true });

    public void Dispose() => _local.Dispose();
}
