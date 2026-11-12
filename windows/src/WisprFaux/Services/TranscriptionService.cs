using System.Diagnostics;
using System.Text;
using Whisper.net;
using Whisper.net.LibraryLoader;
using WisprFaux.Core.Settings;
using WisprFaux.Platform;

namespace WisprFaux.Services;

/// <summary>
/// On-device Whisper through whisper.cpp (Whisper.net). Loads the model once at launch and
/// transcribes each recording; nothing leaves the PC. Runs on the GPU through Vulkan when
/// there is one, otherwise on the CPU.
/// </summary>
sealed class TranscriptionService : IDisposable
{
    public enum Phase { NotDownloaded, Downloading, Loading, Ready, Failed }

    public sealed record Result(string Text, TimeSpan AudioDuration, TimeSpan ProcessingDuration);

    readonly SemaphoreSlim _gate = new(1, 1);
    WhisperFactory? _factory;
    Task? _loadTask;

    public ModelFile Model { get; private set; }
    public Phase Status { get; private set; }
    public double DownloadFraction { get; private set; }
    public string? Error { get; private set; }
    public string? Runtime { get; private set; }
    public TimeSpan? LoadTime { get; private set; }
    public event Action? Changed;

    public TranscriptionService(ModelFile model)
    {
        Model = model;
        Status = model.IsDownloaded ? Phase.Loading : Phase.NotDownloaded;
    }

    /// <summary>Has a model or is loading one: a dictation can wait for it.</summary>
    public bool IsAvailable => Status is Phase.Ready or Phase.Loading;

    public string StatusText => Status switch
    {
        Phase.NotDownloaded => $"{Model.DisplayName} isn't downloaded",
        Phase.Downloading => $"Downloading {Model.DisplayName}… {DownloadFraction:P0}",
        Phase.Loading => "Loading speech model…",
        Phase.Ready => $"{Model.DisplayName}{(Runtime is null ? "" : $" on the {Runtime}")}",
        Phase.Failed => Error ?? "Speech model failed to load",
        _ => "",
    };

    void Set(Phase phase, string? error = null)
    {
        Status = phase;
        Error = error;
        Changed?.Invoke();
    }

    public void LoadIfDownloaded(bool useGpu)
    {
        if (!Model.IsDownloaded)
        {
            Set(Phase.NotDownloaded);
            return;
        }
        if (_loadTask is { IsCompleted: false }) return;
        Set(Phase.Loading);
        _loadTask = Task.Run(() => LoadAsync(useGpu));
    }

    async Task LoadAsync(bool useGpu)
    {
        try
        {
            var watch = Stopwatch.StartNew();
            RuntimeOptions.RuntimeLibraryOrder = useGpu
                ? new List<RuntimeLibrary> { RuntimeLibrary.Cuda, RuntimeLibrary.Vulkan, RuntimeLibrary.Cpu, RuntimeLibrary.CpuNoAvx }
                : new List<RuntimeLibrary> { RuntimeLibrary.Cpu, RuntimeLibrary.CpuNoAvx };
            var factory = WhisperFactory.FromPath(Model.LocalPath, new WhisperFactoryOptions { UseGpu = useGpu });
            Runtime = RuntimeOptions.LoadedLibrary switch
            {
                RuntimeLibrary.Vulkan => "GPU (Vulkan)",
                RuntimeLibrary.Cuda or RuntimeLibrary.Cuda12 => "GPU (CUDA)",
                RuntimeLibrary.Cpu or RuntimeLibrary.CpuNoAvx => "CPU",
                null => null,
                var other => other.ToString(),
            };
            // A first pass on silence sets up the GPU kernels, so the first dictation isn't slow.
            await using (var processor = factory.CreateBuilder().WithLanguage("en").Build())
                await foreach (var _ in processor.ProcessAsync(new float[AudioRecorder.SampleRate])) { }
            _factory = factory;
            LoadTime = watch.Elapsed;
            Log.Info("Transcription", $"Loaded {Model.FileName} on {Runtime ?? "?"} in {watch.ElapsedMilliseconds} ms");
            Set(Phase.Ready);
        }
        catch (Exception e)
        {
            Log.Error("Transcription", $"Couldn't load {Model.FileName}: {e}");
            Set(Phase.Failed, "Speech model failed to load: " + e.Message);
        }
    }

    public async Task DownloadAsync(bool useGpu)
    {
        if (Status is Phase.Downloading) return;
        DownloadFraction = 0;
        Set(Phase.Downloading);
        try
        {
            var model = Model;
            await ModelDownloader.DownloadAsync(model, new Progress<double>(f =>
            {
                DownloadFraction = f;
                Changed?.Invoke();
            }));
            LoadIfDownloaded(useGpu);
        }
        catch (Exception e)
        {
            Log.Error("Models", "Whisper download failed: " + e.Message);
            Set(Phase.Failed, "Download failed: " + e.Message);
        }
    }

    /// <summary>Switches models (Settings). The new one loads, or waits to be downloaded.</summary>
    public void SetModel(ModelFile model, bool useGpu)
    {
        if (model == Model && Status is not Phase.Failed) return;
        Model = model;
        var old = _factory;
        _factory = null;
        _ = Task.Run(async () =>
        {
            await _gate.WaitAsync();
            try { old?.Dispose(); } finally { _gate.Release(); }
        });
        LoadIfDownloaded(useGpu);
    }

    /// <summary>Transcribes 16 kHz mono audio. Waits for the model if it's still loading.</summary>
    public Task<Result?> TranscribeAsync(float[] samples, string language, CancellationToken cancellationToken) =>
        Task.Run(() => TranscribeCoreAsync(samples, language, cancellationToken), cancellationToken);

    async Task<Result?> TranscribeCoreAsync(float[] samples, string language, CancellationToken cancellationToken)
    {
        if (_loadTask is { } loading) await loading.WaitAsync(cancellationToken);

        await _gate.WaitAsync(cancellationToken);
        try
        {
            // Read under the gate: switching models disposes the old one under it too.
            var factory = _factory;
            if (factory is null) return null;
            var watch = Stopwatch.StartNew();
            // whisper.cpp wants at least a second of audio; pad short clips with silence.
            var audio = samples.Length >= AudioRecorder.SampleRate * 1.1
                ? samples
                : samples.Concat(new float[(int)(AudioRecorder.SampleRate * 1.1) - samples.Length]).ToArray();
            var builder = factory.CreateBuilder()
                .WithLanguage(string.IsNullOrWhiteSpace(language) ? "auto" : language)
                .WithThreads(Math.Clamp(Environment.ProcessorCount / 2, 2, 8))
                .WithNoContext();
            await using var processor = builder.Build();
            var text = new StringBuilder();
            await foreach (var segment in processor.ProcessAsync(audio, cancellationToken))
                text.Append(segment.Text);
            var result = new Result(text.ToString().Trim(), TimeSpan.FromSeconds(samples.Length / (double)AudioRecorder.SampleRate), watch.Elapsed);
            Log.Info("Transcription", $"{result.AudioDuration.TotalSeconds:0.00} s of audio in {result.ProcessingDuration.TotalMilliseconds:0} ms, {result.Text.Length} characters");
            return result;
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception e)
        {
            Log.Error("Transcription", "Transcription failed: " + e.Message);
            return null;
        }
        finally
        {
            _gate.Release();
        }
    }

    public void Dispose() => _factory?.Dispose();
}
