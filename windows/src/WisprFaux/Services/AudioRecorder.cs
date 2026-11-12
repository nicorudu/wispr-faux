using System.Diagnostics;
using Microsoft.Win32;
using NAudio.Wave;
using WisprFaux.Core.Audio;
using WisprFaux.Platform;

namespace WisprFaux.Services;

sealed record Recording(float[] Samples, TimeSpan Duration, LevelStats Levels, string Device, TimeSpan FirstSampleAfter);

/// <summary>
/// Records the microphone as 16 kHz mono while the hotkey is held. Windows' audio engine
/// converts whatever the device delivers.
///
/// Opening a microphone on Windows can take a second or more (a Bluetooth headset switching to
/// its headset mode, a USB mic waking up), and whatever is said meanwhile would be lost. So by
/// default (<see cref="KeepReady"/>) the device stays open and the last fraction of a second is
/// kept in memory: a press starts recording at once, including the moment just before it.
/// Nothing is kept beyond that short rolling buffer, and nothing is written to disk. With
/// KeepReady off, the mic is only open while recording, as on the Mac.
/// </summary>
sealed class AudioRecorder : IDisposable
{
    public const int SampleRate = 16_000;
    static readonly TimeSpan MaxDuration = TimeSpan.FromMinutes(5);
    /// <summary>Audio from just before the press that starts each recording.</summary>
    const int PreRollSamples = SampleRate * 400 / 1000;

    readonly object _lock = new();
    WaveInEvent? _wave;
    TaskCompletionSource? _stopped;
    int _openDevice = int.MinValue;
    string _deviceName = "";
    long _lastDataTicks;

    bool _recording;
    List<float> _samples = new();
    Stopwatch? _startedAt;
    TimeSpan? _firstSample;
    int _preRolled;

    readonly float[] _ring = new float[PreRollSamples];
    int _ringPos, _ringCount;
    volatile float _level;

    /// <summary>Keep the device open between recordings (see the class summary).</summary>
    public bool KeepReady { get; set; } = true;
    /// <summary>Live level, 0…1, while recording.</summary>
    public float Level => _level;
    public bool IsRecording { get { lock (_lock) return _recording; } }

    /// <summary>
    /// Open, but nothing has arrived for a while: the device went away, or the PC slept. The
    /// next start reopens it.
    /// </summary>
    public bool IsStale
    {
        get
        {
            lock (_lock) return _wave is null || Environment.TickCount64 - _lastDataTicks > 2000;
        }
    }

    public static IReadOnlyList<(int Number, string Name)> Devices()
    {
        var list = new List<(int, string)>();
        for (var i = 0; i < WaveInEvent.DeviceCount; i++) list.Add((i, WaveInEvent.GetCapabilities(i).ProductName));
        return list;
    }

    /// <summary>
    /// The device number to open: the chosen device, found by name first (numbers shift when
    /// devices come and go), or Windows' default microphone.
    /// </summary>
    public static int Resolve(int number, string? name)
    {
        if (number >= 0 && name is not null)
        {
            var devices = Devices();
            foreach (var (n, deviceName) in devices) if (deviceName == name) return n;
            if (number < devices.Count) return number;
        }
        return DefaultDevice();
    }

    /// <summary>Windows' default recording device, as a WinMM device number (-1 if unknown).</summary>
    static int DefaultDevice()
    {
        const uint DRVM_MAPPER_PREFERRED_GET = 0x2015;
        try
        {
            if (Native.waveInMessage(new IntPtr(0xFFFFFFFFL), DRVM_MAPPER_PREFERRED_GET, out var id, out _) == 0
                && id < WaveInEvent.DeviceCount)
                return (int)id;
        }
        catch (Exception) { }
        return -1;
    }

    /// <summary>Opens the device ahead of the first press (KeepReady only).</summary>
    public Task WarmUpAsync(int deviceNumber) => Task.Run(() =>
    {
        if (!KeepReady) return;
        lock (_lock)
        {
            if (_recording) return;
            if (_wave is not null && _openDevice == deviceNumber && !StaleLocked()) return;
        }
        Close();
        lock (_lock) OpenLocked(deviceNumber);
        Log.Info("Audio", $"Microphone ready: {_deviceName}");
    });

    public Task StartAsync(int deviceNumber) => Task.Run(() =>
    {
        WaveInEvent? reopen = null;
        lock (_lock)
        {
            if (_recording) return;
            if (_wave is not null && (_openDevice != deviceNumber || StaleLocked())) reopen = _wave;
        }
        if (reopen is not null) Close();
        lock (_lock)
        {
            var warm = _wave is not null;
            if (!warm) OpenLocked(deviceNumber);
            _samples = new List<float>(SampleRate * 10);
            _startedAt = Stopwatch.StartNew();
            _firstSample = null;
            _level = 0;
            _preRolled = 0;
            if (warm)
            {
                // The moment just before the press, from the rolling buffer.
                var start = (_ringPos - _ringCount + _ring.Length) % _ring.Length;
                for (var i = 0; i < _ringCount; i++) _samples.Add(_ring[(start + i) % _ring.Length]);
                _preRolled = _ringCount;
                _firstSample = TimeSpan.Zero;
            }
            _ringCount = 0;
            _recording = true;
        }
    });

    bool StaleLocked() => Environment.TickCount64 - _lastDataTicks > 2000;

    void OpenLocked(int deviceNumber)
    {
        _deviceName = deviceNumber >= 0 && deviceNumber < WaveInEvent.DeviceCount
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
            if (e.Exception is not null) Log.Error("Audio", "Microphone stopped: " + e.Exception.Message);
            stopped.TrySetResult();
            lock (_lock)
            {
                if (_wave != wave) return;
                // Unplugged or failed: the next start opens it again.
                _wave = null;
                _stopped = null;
            }
            Task.Run(wave.Dispose);
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
        _openDevice = deviceNumber;
        _lastDataTicks = Environment.TickCount64;
        _ringCount = 0;
    }

    void OnData(object? sender, WaveInEventArgs e)
    {
        var count = e.BytesRecorded / 2;
        float peak = 0;
        lock (_lock)
        {
            if (sender != _wave) return;
            _lastDataTicks = Environment.TickCount64;
            if (!_recording)
            {
                for (var i = 0; i < count; i++)
                {
                    _ring[_ringPos] = BitConverter.ToInt16(e.Buffer, i * 2) / 32768f;
                    _ringPos = (_ringPos + 1) % _ring.Length;
                }
                _ringCount = Math.Min(_ring.Length, _ringCount + count);
                return;
            }
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
    /// Ends the recording and returns it. Waits briefly first so the buffer holding the end of
    /// the last word arrives.
    /// </summary>
    public async Task<Recording?> StopAsync()
    {
        lock (_lock) if (!_recording) return null;
        await Task.Delay(80);
        float[] samples;
        TimeSpan? first;
        string device;
        int preRolled;
        lock (_lock)
        {
            if (!_recording) return null;
            _recording = false;
            samples = _samples.ToArray();
            _samples = new();
            first = _firstSample;
            device = _deviceName;
            preRolled = _preRolled;
        }
        _level = 0;
        if (!KeepReady) await Task.Run(Close);
        var duration = TimeSpan.FromSeconds(samples.Length / (double)SampleRate);
        if (preRolled > 0) Log.Info("Audio", $"Included {preRolled * 1000 / SampleRate} ms from before the press");
        return new Recording(samples, duration, LevelStats.Of(samples), device, first ?? TimeSpan.Zero);
    }

    /// <summary>Ends the recording and throws the audio away (Esc).</summary>
    public void Cancel()
    {
        lock (_lock)
        {
            _recording = false;
            _samples = new();
        }
        _level = 0;
        if (!KeepReady) Task.Run(Close);
    }

    /// <summary>Closes the device (and waits for it to stop).</summary>
    public void Close()
    {
        WaveInEvent? wave;
        TaskCompletionSource? stopped;
        lock (_lock)
        {
            wave = _wave;
            stopped = _stopped;
            _wave = null;
            _stopped = null;
            _ringCount = 0;
        }
        if (wave is null) return;
        try { wave.StopRecording(); } catch (Exception e) { Log.Error("Audio", "Stop failed: " + e.Message); }
        stopped?.Task.Wait(500);
        wave.Dispose();
    }

    public void Dispose() => Close();
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
