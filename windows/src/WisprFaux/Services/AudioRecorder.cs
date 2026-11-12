using System.Diagnostics;
using Microsoft.Win32;
using NAudio.Wave;
using WisprFaux.Core.Audio;
using WisprFaux.Platform;

namespace WisprFaux.Services;

sealed record Recording(float[] Samples, TimeSpan Duration, LevelStats Levels, string Device, TimeSpan FirstSampleAfter);

/// <summary>
/// Records the microphone as 16 kHz mono while the hotkey is held. Windows' audio engine
/// converts whatever the device delivers. The mic is only open while recording: no always-on
/// microphone (and no microphone icon in the taskbar otherwise).
/// </summary>
sealed class AudioRecorder
{
    public const int SampleRate = 16_000;
    static readonly TimeSpan MaxDuration = TimeSpan.FromMinutes(5);

    readonly object _lock = new();
    WaveInEvent? _wave;
    List<float> _samples = new();
    TaskCompletionSource? _stopped;
    Stopwatch? _startedAt;
    TimeSpan? _firstSample;
    string _device = "";
    volatile float _level;

    /// <summary>Live level, 0…1, while recording.</summary>
    public float Level => _level;
    public bool IsRecording { get { lock (_lock) return _wave is not null; } }

    public static IReadOnlyList<(int Number, string Name)> Devices()
    {
        var list = new List<(int, string)>();
        for (var i = 0; i < WaveInEvent.DeviceCount; i++) list.Add((i, WaveInEvent.GetCapabilities(i).ProductName));
        return list;
    }

    /// <summary>Finds the device by name first (numbers shift when devices come and go).</summary>
    public static int Resolve(int number, string? name)
    {
        if (number < 0 || name is null) return -1;
        var devices = Devices();
        foreach (var (n, deviceName) in devices) if (deviceName == name) return n;
        return number < devices.Count ? number : -1;
    }

    public Task StartAsync(int deviceNumber) => Task.Run(() =>
    {
        lock (_lock)
        {
            if (_wave is not null) return;
            _samples = new List<float>(SampleRate * 10);
            _firstSample = null;
            _level = 0;
            _startedAt = Stopwatch.StartNew();
            _device = deviceNumber >= 0 && deviceNumber < WaveInEvent.DeviceCount
                ? WaveInEvent.GetCapabilities(deviceNumber).ProductName
                : "Windows default microphone";
            var wave = new WaveInEvent
            {
                DeviceNumber = deviceNumber,
                WaveFormat = new WaveFormat(SampleRate, 16, 1),
                BufferMilliseconds = 50,
                NumberOfBuffers = 4,
            };
            var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            wave.DataAvailable += OnData;
            wave.RecordingStopped += (_, e) =>
            {
                if (e.Exception is not null) Log.Error("Audio", "Recording stopped: " + e.Exception.Message);
                stopped.TrySetResult();
            };
            try
            {
                wave.StartRecording();
            }
            catch
            {
                wave.Dispose();
                throw;
            }
            _wave = wave;
            _stopped = stopped;
        }
    });

    void OnData(object? sender, WaveInEventArgs e)
    {
        var count = e.BytesRecorded / 2;
        float peak = 0;
        lock (_lock)
        {
            if (sender != _wave) return;
            _firstSample ??= _startedAt?.Elapsed;
            if (_samples.Count >= SampleRate * MaxDuration.TotalSeconds) return;
            for (var i = 0; i < count; i++)
            {
                var s = BitConverter.ToInt16(e.Buffer, i * 2) / 32768f;
                _samples.Add(s);
                var a = Math.Abs(s);
                if (a > peak) peak = a;
            }
        }
        _level = Decibels.MeterValue(peak);
    }

    /// <summary>
    /// Stops the mic and returns what was recorded. Waits briefly first so the buffer holding
    /// the end of the last word arrives.
    /// </summary>
    public async Task<Recording?> StopAsync()
    {
        WaveInEvent? wave;
        TaskCompletionSource? stopped;
        lock (_lock)
        {
            wave = _wave;
            stopped = _stopped;
        }
        if (wave is null) return null;
        await Task.Delay(80);
        await Task.Run(() =>
        {
            try { wave.StopRecording(); } catch (Exception e) { Log.Error("Audio", "Stop failed: " + e.Message); }
        });
        if (stopped is not null) await Task.WhenAny(stopped.Task, Task.Delay(500));
        float[] samples;
        TimeSpan? first;
        string device;
        lock (_lock)
        {
            samples = _samples.ToArray();
            first = _firstSample;
            device = _device;
            _wave = null;
            _stopped = null;
        }
        wave.Dispose();
        _level = 0;
        var duration = TimeSpan.FromSeconds(samples.Length / (double)SampleRate);
        return new Recording(samples, duration, LevelStats.Of(samples), device, first ?? TimeSpan.Zero);
    }

    /// <summary>Stops the mic and throws the audio away (Esc).</summary>
    public void Cancel()
    {
        WaveInEvent? wave;
        lock (_lock)
        {
            wave = _wave;
            _wave = null;
            _stopped = null;
            _samples = new();
        }
        _level = 0;
        if (wave is null) return;
        Task.Run(() =>
        {
            try { wave.StopRecording(); } catch (Exception) { }
            Thread.Sleep(200);
            wave.Dispose();
        });
    }
}

/// <summary>Windows Settings → Privacy &amp; security → Microphone.</summary>
static class MicrophonePrivacy
{
    const string Key = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

    /// <summary>
    /// True when Windows blocks desktop apps from the microphone: either microphone access is
    /// off altogether, or "Let desktop apps access your microphone" is off. Windows then hands
    /// apps silence instead of an error.
    /// </summary>
    public static bool IsBlocked()
    {
        static bool Denied(RegistryKey root, string path)
        {
            using var key = root.OpenSubKey(path);
            return string.Equals(key?.GetValue("Value") as string, "Deny", StringComparison.OrdinalIgnoreCase);
        }
        try
        {
            return Denied(Registry.LocalMachine, Key) || Denied(Registry.CurrentUser, Key) || Denied(Registry.CurrentUser, Key + @"\NonPackaged");
        }
        catch (Exception) { return false; }
    }

    public const string SettingsUri = "ms-settings:privacy-microphone";
}
