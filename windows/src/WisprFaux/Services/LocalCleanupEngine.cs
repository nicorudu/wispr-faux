using System.Diagnostics;
using System.Text;
using LLama;
using LLama.Common;
using LLama.Sampling;
using WisprFaux.Core.Cleanup;
using WisprFaux.Core.Settings;

namespace WisprFaux.Services;

/// <summary>
/// Cleanup with a small language model on this PC through llama.cpp (LLamaSharp): the Mac
/// app's Qwen3 1.7B, as a GGUF file. Loads only from the downloaded file, so nothing leaves
/// the PC.
/// </summary>
sealed class LocalCleanupEngine : ICleanupEngine, IDisposable
{
    readonly ModelFile _model;
    readonly bool _useGpu;
    readonly SemaphoreSlim _gate = new(1, 1);
    readonly object _loadLock = new();
    LLamaWeights? _weights;
    ModelParams? _params;
    Task<TimeSpan>? _loadTask;

    public LocalCleanupEngine(ModelFile model, bool useGpu)
    {
        _model = model;
        _useGpu = useGpu;
    }

    public string Name => $"{_model.DisplayName} (on this PC)";

    /// <summary>Loads the model; returns how long that took. Later calls return at once.</summary>
    public Task<TimeSpan> LoadAsync()
    {
        lock (_loadLock)
        {
            if (_loadTask is { IsFaulted: false }) return _loadTask;
            return _loadTask = Task.Run(async () =>
            {
                if (!_model.IsDownloaded) throw new InvalidOperationException($"{_model.DisplayName} isn't downloaded yet.");
                var watch = Stopwatch.StartNew();
                var parameters = new ModelParams(_model.LocalPath)
                {
                    ContextSize = 1024,
                    GpuLayerCount = _useGpu ? 99 : 0,
                    Threads = Math.Clamp(Environment.ProcessorCount / 2, 2, 8),
                };
                _weights = await LLamaWeights.LoadFromFileAsync(parameters);
                _params = parameters;
                return watch.Elapsed;
            });
        }
    }

    public Task<string> CompleteAsync(
        string instructions,
        IReadOnlyList<(string Dictated, string Cleaned)> examples,
        string text,
        int maxTokens,
        CancellationToken cancellationToken) =>
        // llama.cpp does its work synchronously; keep it off the UI thread.
        Task.Run(() => CompleteCoreAsync(instructions, examples, text, maxTokens, cancellationToken), cancellationToken);

    async Task<string> CompleteCoreAsync(
        string instructions,
        IReadOnlyList<(string Dictated, string Cleaned)> examples,
        string text,
        int maxTokens,
        CancellationToken cancellationToken)
    {
        await LoadAsync().WaitAsync(cancellationToken);
        if (_weights is null || _params is null) throw new InvalidOperationException("The cleanup model isn't loaded.");

        await _gate.WaitAsync(cancellationToken);
        try
        {
            // A fresh context per transcript (nothing carries over between dictations), just
            // big enough for the prompt and the longest possible reply.
            var prompt = CleanupPrompt.ChatML(instructions, examples, text);
            var promptTokens = _weights.Tokenize(prompt, true, true, Encoding.UTF8).Length;
            var needed = promptTokens + maxTokens + 16;
            var context = new ModelParams(_model.LocalPath)
            {
                ContextSize = (uint)(Math.Ceiling(needed / 512.0) * 512),
                GpuLayerCount = _params.GpuLayerCount,
                Threads = _params.Threads,
            };
            var executor = new StatelessExecutor(_weights, context);
            var inference = new InferenceParams
            {
                MaxTokens = maxTokens,
                AntiPrompts = new[] { "<|im_end|>", "<|im_start|>" },
                SamplingPipeline = new DefaultSamplingPipeline { Temperature = 0 },
            };
            var reply = new StringBuilder();
            await foreach (var piece in executor.InferAsync(prompt, inference, cancellationToken))
                reply.Append(piece);
            var result = reply.ToString();
            foreach (var stop in inference.AntiPrompts)
            {
                var at = result.IndexOf(stop, StringComparison.Ordinal);
                if (at >= 0) result = result[..at];
            }
            return result;
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>Waits (briefly) for a cleanup in progress before freeing the model.</summary>
    public void Dispose()
    {
        var idle = _gate.Wait(TimeSpan.FromSeconds(3));
        try { _weights?.Dispose(); _weights = null; }
        finally { if (idle) _gate.Release(); }
    }
}
