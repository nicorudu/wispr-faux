namespace WisprFaux.Core.Settings;

/// <summary>A model file Wispr Faux can download.</summary>
public sealed record ModelFile(string Id, string DisplayName, string FileName, string Url, long ApproximateBytes, string Note)
{
    public string LocalPath => Path.Combine(AppPaths.Models, FileName);

    public bool IsDownloaded
    {
        get
        {
            var info = new FileInfo(LocalPath);
            // A partial file never has the final name (downloads go to *.part first), but a
            // stray tiny file (an HTML error page saved by hand) shouldn't count either.
            return info.Exists && info.Length > ApproximateBytes / 2;
        }
    }

    public string SizeText => ApproximateBytes >= 1_000_000_000
        ? $"{ApproximateBytes / 1e9:0.0} GB"
        : $"{ApproximateBytes / 1e6:0} MB";
}

public static class ModelCatalog
{
    const string WhisperBase = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/";

    /// <summary>Whisper large-v3 turbo, 5-bit: the counterpart of the Mac app's compressed turbo model.</summary>
    public static readonly ModelFile TurboQ5 = new(
        "large-v3-turbo-q5_0", "Whisper large-v3 turbo (5-bit)", "ggml-large-v3-turbo-q5_0.bin",
        WhisperBase + "ggml-large-v3-turbo-q5_0.bin", 574_000_000, "Default: fast, accurate, multilingual");

    public static readonly ModelFile TurboQ8 = new(
        "large-v3-turbo-q8_0", "Whisper large-v3 turbo (8-bit)", "ggml-large-v3-turbo-q8_0.bin",
        WhisperBase + "ggml-large-v3-turbo-q8_0.bin", 874_000_000, "Slightly more accurate, larger");

    public static readonly ModelFile Turbo = new(
        "large-v3-turbo", "Whisper large-v3 turbo (full)", "ggml-large-v3-turbo.bin",
        WhisperBase + "ggml-large-v3-turbo.bin", 1_620_000_000, "Unquantized; needs a GPU to be quick");

    public static readonly ModelFile SmallEn = new(
        "small.en", "Whisper small (English only)", "ggml-small.en.bin",
        WhisperBase + "ggml-small.en.bin", 488_000_000, "For slow PCs without a GPU");

    public static readonly IReadOnlyList<ModelFile> Whisper = new[] { TurboQ5, TurboQ8, Turbo, SmallEn };

    public static ModelFile WhisperNamed(string? id) => Whisper.FirstOrDefault(m => m.Id == id) ?? TurboQ5;

    /// <summary>
    /// Qwen3 1.7B, the Mac app's on-device cleanup model, as a 4-bit GGUF for llama.cpp.
    /// </summary>
    public static readonly ModelFile CleanupQwen3 = new(
        "qwen3-1.7b", "Qwen3 1.7B", "Qwen3-1.7B-Q4_K_M.gguf",
        "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf",
        1_110_000_000, "Stumble cleanup on this PC");
}
