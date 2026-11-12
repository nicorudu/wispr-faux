using System.Text.Json;
using System.Text.Json.Serialization;
using WisprFaux.Core.Hotkey;

namespace WisprFaux.Core.Settings;

public enum CleanupMode { Off, OnDevice, Cloud }

/// <summary>Everything the user can change, saved as JSON in %LOCALAPPDATA%\Wispr Faux\settings.json.</summary>
public sealed class AppSettings
{
    public List<HotkeyTrigger> Triggers { get; set; } = HotkeyTriggers.Default.ToList();

    /// <summary>WinMM device number; -1 follows the Windows default microphone.</summary>
    public int MicrophoneDevice { get; set; } = -1;
    /// <summary>The device's name, so the choice survives devices being renumbered.</summary>
    public string? MicrophoneName { get; set; }
    /// <summary>
    /// Keep the microphone open between dictations, so none of the first words are lost while a
    /// device starts up. Windows then shows the microphone as in use.
    /// </summary>
    public bool KeepMicrophoneReady { get; set; } = true;

    public string WhisperModel { get; set; } = ModelCatalog.TurboQ5.Id;
    /// <summary>"auto" detects the language of each dictation; "en", "es", … fix it.</summary>
    public string Language { get; set; } = "auto";
    /// <summary>Runs Whisper and the cleanup model on the GPU through Vulkan when there is one.</summary>
    public bool UseGpu { get; set; } = true;

    /// <summary>Null until the user picks: then On this PC once its model is there, otherwise Off.</summary>
    public CleanupMode? Cleanup { get; set; }
    public string CloudProvider { get; set; } = WisprFaux.Core.Cleanup.CloudProvider.GlmFlash.Id;

    /// <summary>How long to wait before putting the clipboard back after Ctrl+V.</summary>
    public int ClipboardRestoreDelayMs { get; set; } = 500;

    static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    public static AppSettings Load(string? path = null)
    {
        path ??= AppPaths.Settings;
        try
        {
            if (File.Exists(path))
            {
                var settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path), Json) ?? new();
                if (settings.Triggers.Count == 0) settings.Triggers = HotkeyTriggers.Default.ToList();
                return settings;
            }
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { }
        return new AppSettings();
    }

    public void Save(string? path = null)
    {
        path ??= AppPaths.Settings;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temp = path + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(this, Json));
            File.Move(temp, path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
