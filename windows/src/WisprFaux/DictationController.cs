using System.Diagnostics;
using WisprFaux.Core.Audio;
using WisprFaux.Core.Cleanup;
using WisprFaux.Core.History;
using WisprFaux.Core.Hotkey;
using WisprFaux.Core.Settings;
using WisprFaux.Core.Text;
using WisprFaux.Platform;
using WisprFaux.Services;
using WisprFaux.UI;

namespace WisprFaux;

/// <summary>
/// Owns the dictation state machine, as on the Mac:
///
///     idle ─hotkey down─▶ recording ─hotkey up─▶ transcribing ─▶ inserting ─▶ idle
///
/// Holding the trigger records; releasing it stops the mic, and a recording that passes the
/// speech gate is transcribed on-device, cleaned up, and pasted into the focused field with
/// the user's clipboard put back. Password fields are never pasted into; when focus isn't on a
/// text field, the app runs as administrator, or the user switched apps meanwhile, the text is
/// copied instead and the pill says so. Esc cancels while recording or transcribing. Every
/// transcript goes into the history.
///
/// Everything here runs on the UI thread; slow work (Whisper, the cleanup model) runs on the
/// thread pool inside the services.
/// </summary>
sealed class DictationController : IDisposable
{
    public enum State { Idle, Recording, Transcribing, Inserting }

    readonly AppSettings _settings;
    readonly InputHook _hook;
    readonly AudioRecorder _recorder = new();
    readonly TextInserter _inserter = new();
    readonly SpeechGate _gate = SpeechGate.Default;
    readonly StatusPill _pill = new();
    readonly System.Windows.Forms.Timer _poll = new() { Interval = 250 };
    readonly ForegroundTracker _foreground = new();

    int _dictationCount;
    int? _transcribingId;
    readonly HashSet<int> _cancelledIds = new();
    CancellationTokenSource? _transcriptionCancel;
    Stopwatch? _pressStarted;
    bool _handsFree;
    long _lastHookReinstall;
    PillContent? _notice;
    System.Windows.Forms.Timer? _noticeTimer;

    public State CurrentState { get; private set; } = State.Idle;
    public HistoryStore History { get; } = new(AppPaths.History);
    public TranscriptionService Transcription { get; }
    public CleanupService Cleanup { get; }
    public AppSettings Settings => _settings;
    public string? LastTiming { get; private set; }
    public string? HookError { get; private set; }
    public event Action? Changed;

    public DictationController(AppSettings settings)
    {
        _settings = settings;
        _hook = new InputHook(settings.Triggers.ToHashSet());
        Transcription = new TranscriptionService(ModelCatalog.WhisperNamed(settings.WhisperModel));
        Cleanup = new CleanupService(settings);
        Transcription.Changed += NotifyFromAnyThread;
        Cleanup.Changed += NotifyFromAnyThread;
        _poll.Tick += (_, _) => Poll();
    }

    SynchronizationContext? _ui;

    void NotifyFromAnyThread()
    {
        if (_ui is null || SynchronizationContext.Current == _ui) Changed?.Invoke();
        else _ui.Post(_ => Changed?.Invoke(), null);
    }

    public string TriggerDescription => HotkeyTriggers.Describe(_settings.Triggers.ToHashSet());

    // MARK: Lifecycle

    public void Start()
    {
        _ui = SynchronizationContext.Current;
        Transcription.LoadIfDownloaded(_settings.UseGpu);
        Cleanup.Start();
        try
        {
            _hook.Start();
        }
        catch (Exception e)
        {
            HookError = e.Message;
            Log.Error("Hotkey", "Couldn't install the keyboard hook: " + e.Message);
        }
        _foreground.Start();
        _poll.Start();
        _ = ProcessEventsAsync();
        Log.Info("App", $"Started. Triggers: {TriggerDescription}; model: {Transcription.Model.FileName}; cleanup: {Cleanup.Mode}; elevated: {Native.IsCurrentProcessElevated()}");
    }

    async Task ProcessEventsAsync()
    {
        // One event at a time: a release waits for the microphone to finish starting.
        await foreach (var e in _hook.Events.ReadAllAsync())
        {
            try { await HandleAsync(e); }
            catch (Exception ex) { Log.Error("App", $"Handling {e} failed: {ex}"); }
        }
    }

    public void Dispose()
    {
        _poll.Stop();
        _hook.Dispose();
        _foreground.Dispose();
        _recorder.Cancel();
        // Don't quit with Wispr Faux's text still standing in for the user's clipboard.
        _inserter.RestoreNow();
        _pill.Dispose();
        Transcription.Dispose();
        Cleanup.Dispose();
    }

    // MARK: Hotkey events

    async Task HandleAsync(HotkeyEvent e)
    {
        switch (e)
        {
            case HotkeyEvent.PushToTalkPressed:
                _dictationCount++;
                _pressStarted = Stopwatch.StartNew();
                _handsFree = false;
                ClearNotice();
                SetState(State.Recording);
                // Letting go of Alt alone would open the app's menu bar; a dummy key prevents it.
                if (_hook.HeldTrigger == HotkeyTrigger.RightAlt) TextInserter.SendMaskKey();
                await StartRecordingAsync();
                break;

            case HotkeyEvent.HandsFreeToggled:
                _handsFree = true;
                Log.Info("Hotkey", "Hands-free locked");
                UpdatePill();
                break;

            case HotkeyEvent.PushToTalkReleased:
                var held = _pressStarted?.Elapsed;
                var releasedAt = Stopwatch.StartNew();
                var recording = _recorder.IsRecording ? await _recorder.StopAsync() : null;
                EndSession();
                if (recording is not null)
                {
                    Log.Info("Audio", $"Recorded {recording.Duration.TotalSeconds:0.00} s (held {held?.TotalMilliseconds:0} ms) from {recording.Device}, loudest {recording.Levels.LoudestWindowDbfs:0} dBFS, first sample after {recording.FirstSampleAfter.TotalMilliseconds:0} ms");
                    StartTranscription(recording, _dictationCount, releasedAt);
                }
                break;

            case HotkeyEvent.Cancel:
                if (_pressStarted is not null)
                {
                    Log.Info("Hotkey", "Dictation cancelled while recording");
                    _recorder.Cancel();
                    EndSession();
                }
                else if (_transcribingId is { } id)
                {
                    Log.Info("Hotkey", "Dictation cancelled while transcribing");
                    _cancelledIds.Add(id);
                    _transcriptionCancel?.Cancel();
                    FinishTranscribing(id);
                    SetState(State.Idle);
                    ShowNotice("Cancelled");
                }
                break;
        }
    }

    async Task StartRecordingAsync()
    {
        if (MicrophonePrivacy.IsBlocked())
        {
            Log.Info("Audio", "Not recording: Windows blocks desktop apps from the microphone");
            SetState(State.Idle);
            ShowNotice("Microphone access is off in Windows Settings → Privacy", warning: true);
            return;
        }
        try
        {
            var device = AudioRecorder.Resolve(_settings.MicrophoneDevice, _settings.MicrophoneName);
            await _recorder.StartAsync(device);
            // Released while the mic was starting: the release handler already ran.
            if (CurrentState != State.Recording) _recorder.Cancel();
        }
        catch (Exception e)
        {
            Log.Error("Audio", "Recording failed to start: " + e.Message);
            SetState(State.Idle);
            _pressStarted = null;
            ShowNotice("Couldn't open the microphone: " + e.Message, warning: true);
        }
    }

    void EndSession()
    {
        _pressStarted = null;
        _handsFree = false;
        SetState(State.Idle);
    }

    // MARK: Transcribing and pasting

    void StartTranscription(Recording recording, int id, Stopwatch releasedAt)
    {
        switch (_gate.Verdict(recording.Duration, recording.Levels))
        {
            case GateVerdict.TooShort:
                return; // An accidental tap: nothing to say about it.
            case GateVerdict.TooQuiet:
                ShowNotice("Didn't hear anything. Check the microphone", warning: true);
                return;
        }
        if (!Transcription.IsAvailable)
        {
            ShowNotice("Download the speech model first (see the tray menu)", warning: true);
            return;
        }

        var targetProcess = Native.ProcessId(Native.GetForegroundWindow());
        SetState(State.Transcribing);
        _transcribingId = id;
        _hook.SetEscapeCancels(true);
        var cancel = new CancellationTokenSource();
        _transcriptionCancel = cancel;
        _ = RunAsync();

        async Task RunAsync()
        {
            TranscriptionService.Result? result = null;
            Prepared? prepared = null;
            try
            {
                result = await Transcription.TranscribeAsync(recording.Samples, _settings.Language, cancel.Token);
                // Cleanup runs before Esc stops cancelling, so Esc covers it too.
                if (result is not null) prepared = await PrepareAsync(result, recording, cancel.Token);
            }
            catch (OperationCanceledException) { }
            FinishTranscribing(id);
            if (_cancelledIds.Remove(id)) return;

            if (CurrentState == State.Transcribing) SetState(State.Inserting);
            if (result is null) ShowNotice("Transcription failed", warning: true);
            else if (prepared is null) ShowNotice("Didn't catch that");
            else await DeliverAsync(prepared, result, targetProcess, releasedAt);
            // A new recording may have started meanwhile; leave its state alone.
            if (CurrentState is State.Inserting or State.Transcribing) SetState(State.Idle);
        }
    }

    void FinishTranscribing(int id)
    {
        if (_transcribingId != id) return;
        _transcribingId = null;
        _hook.SetEscapeCancels(false);
    }

    sealed record Prepared(string Text, string Spoken, CleanupOutcome? Cleanup);

    /// <summary>Tidies the transcript, drops non-speech, and fixes stumbles when cleanup is on.</summary>
    async Task<Prepared?> PrepareAsync(TranscriptionService.Result result, Recording recording, CancellationToken token)
    {
        var text = TextCleaner.Clean(result.Text);
        // Whisper describes silence ("[BLANK_AUDIO]") or invents a polite phrase for it.
        var quiet = recording.Levels.LoudestWindowDbfs < -40;
        if (text.Length == 0 || TextCleaner.IsNonSpeechMarker(text) || (quiet && TextCleaner.IsLikelySilenceArtifact(text)))
        {
            Log.Info("Paste", $"Dropped a non-speech transcript ({text.Length} characters)");
            return null;
        }
        var outcome = await Cleanup.CleanAsync(text, token);
        return new Prepared(outcome?.Text ?? text, text, outcome);
    }

    async Task DeliverAsync(Prepared prepared, TranscriptionService.Result result, uint targetProcess, Stopwatch releasedAt)
    {
        var field = FocusedField.Read();
        History.Add(new TranscriptRecord(prepared.Text, DateTimeOffset.Now, field.AppName,
            prepared.Text == prepared.Spoken ? null : prepared.Spoken));
        var switchedApps = targetProcess != 0 && field.ProcessId != targetProcess;
        var outcome = await InsertOrCopyAsync(prepared.Text, field, switchedApps);

        var cleanupNote = prepared.Cleanup is { } c ? $" → {c.Duration.TotalSeconds:0.00} s cleanup ({c.Describe()})" : "";
        LastTiming = $"{result.AudioDuration.TotalSeconds:0.00} s audio → {result.ProcessingDuration.TotalSeconds:0.00} s to transcribe{cleanupNote} → {outcome} {releasedAt.Elapsed.TotalSeconds:0.00} s after release";
        Log.Info("Paste", $"{outcome} {prepared.Text.Length} characters into {field.AppName ?? "?"} ({field.ControlType ?? "no type"}, {field.Kind}). {LastTiming}");
        Changed?.Invoke();
    }

    /// <summary>
    /// Pastes the text into the focused field, or copies it when pasting isn't safe or can't
    /// work, and says which in the pill. Returns "pasted" or "copied".
    /// </summary>
    async Task<string> InsertOrCopyAsync(string text, FieldInfo field, bool switchedApps)
    {
        switch (field.Kind)
        {
            case FieldKind.Secure:
                CopyToClipboard(text);
                ShowNotice("Password field: not pasted. Copied instead", warning: true);
                return "copied";
            case FieldKind.NotText:
                CopyToClipboard(text);
                ShowNotice("No text field. Copied: press Ctrl+V to paste");
                return "copied";
        }
        if (switchedApps)
        {
            CopyToClipboard(text);
            ShowNotice("You switched apps. Copied: press Ctrl+V to paste");
            return "copied";
        }
        if (field.ProcessId != 0 && Native.IsElevated(field.ProcessId) && !Native.IsCurrentProcessElevated())
        {
            CopyToClipboard(text);
            ShowNotice("That app runs as administrator, so Windows blocks pasting. Copied: press Ctrl+V", warning: true);
            return "copied";
        }

        var spaced = TextCleaner.NeedsLeadingSpace(field.CharacterBeforeCaret) ? " " + text : text;
        // Two transcripts can finish close together; paste them one after the other.
        while (_inserter.IsInserting) await Task.Delay(20);
        try
        {
            await _inserter.InsertAsync(spaced, _settings.ClipboardRestoreDelayMs);
            return "pasted";
        }
        catch (Exception e)
        {
            CopyToClipboard(text);
            ShowNotice($"Couldn't paste ({e.Message}). Copied instead", warning: true);
            Log.Error("Paste", "Paste failed: " + e.Message);
            return "copied";
        }
    }

    // MARK: Menu actions

    /// <summary>Pastes the newest transcript into the app that was in front before the tray menu.</summary>
    public async Task PasteLastAsync()
    {
        if (History.Latest is not { } record) return;
        if (_foreground.LastOtherWindow is { } window && Native.IsWindow(window)) Native.SetForegroundWindow(window);
        // Let the menu finish closing and the app take focus so Ctrl+V reaches it.
        await Task.Delay(250);
        var outcome = await InsertOrCopyAsync(record.Text, FocusedField.Read(), switchedApps: false);
        Log.Info("Paste", $"Paste Last: {outcome} {record.Text.Length} characters");
    }

    public void Copy(TranscriptRecord record)
    {
        CopyToClipboard(record.Text);
        ShowNotice("Copied");
    }

    public void ClearHistory()
    {
        History.Clear();
        Changed?.Invoke();
    }

    static void CopyToClipboard(string text) => Win32Clipboard.SetText(text, transient: false);

    // MARK: Settings

    public void SetTrigger(HotkeyTrigger trigger, bool enabled)
    {
        var triggers = _settings.Triggers.ToHashSet();
        if (enabled) triggers.Add(trigger); else triggers.Remove(trigger);
        if (triggers.Count == 0 || triggers.SetEquals(_settings.Triggers)) return;
        _settings.Triggers = triggers.OrderBy(t => t).ToList();
        _settings.Save();
        _hook.SetTriggers(triggers);
        Changed?.Invoke();
    }

    public void SetWhisperModel(ModelFile model)
    {
        _settings.WhisperModel = model.Id;
        _settings.Save();
        Transcription.SetModel(model, _settings.UseGpu);
    }

    // MARK: Pill and state

    void SetState(State state)
    {
        if (CurrentState == state) return;
        CurrentState = state;
        UpdatePill();
        Changed?.Invoke();
    }

    void UpdatePill()
    {
        PillContent? content = CurrentState switch
        {
            State.Recording => PillContent.Listening(_handsFree, TriggerDescription),
            State.Transcribing or State.Inserting => PillContent.Working(
                Transcription.Status == TranscriptionService.Phase.Loading ? "Loading speech model…" : "Transcribing…"),
            _ => _notice,
        };
        _pill.Show(content, () => _recorder.Level);
    }

    void ShowNotice(string text, bool warning = false)
    {
        _notice = PillContent.Notice(text, warning);
        _noticeTimer?.Dispose();
        var timer = new System.Windows.Forms.Timer { Interval = warning ? 4000 : 2500 };
        timer.Tick += (_, _) =>
        {
            timer.Dispose();
            if (_noticeTimer != timer) return;
            _notice = null;
            _noticeTimer = null;
            UpdatePill();
        };
        _noticeTimer = timer;
        timer.Start();
        UpdatePill();
    }

    void ClearNotice()
    {
        _noticeTimer?.Dispose();
        _noticeTimer = null;
        _notice = null;
    }

    /// <summary>Checks for a missed key-up while a trigger is held, and that the hook is still alive.</summary>
    void Poll()
    {
        if (_hook.HeldTrigger is not null) _hook.Resync();

        if (!_hook.IsRunning) return;
        var info = new Native.LASTINPUTINFO { cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Native.LASTINPUTINFO>() };
        if (!Native.GetLastInputInfo(ref info)) return;
        // GetLastInputInfo wraps every 49.7 days; compare in the same 32-bit space.
        var sinceHook = unchecked((int)(info.dwTime - (uint)_hook.LastCallbackTicks));
        var now = Environment.TickCount64;
        if (sinceHook > 3000 && now - _lastHookReinstall > 30_000)
        {
            // Input reached Windows that the hook never saw: Windows may have removed it.
            _lastHookReinstall = now;
            Log.Info("Hotkey", "The hook missed recent input; reinstalling it");
            _hook.Reinstall();
        }
    }
}

/// <summary>
/// Remembers the last app window in front that isn't Wispr Faux or the taskbar, so Paste Last
/// from the tray menu can go back to it.
/// </summary>
sealed class ForegroundTracker : IDisposable
{
    readonly Native.WinEventProc _proc;
    IntPtr _hook;

    public IntPtr? LastOtherWindow { get; private set; }

    public ForegroundTracker() => _proc = OnForeground;

    public void Start()
    {
        _hook = Native.SetWinEventHook(Native.EVENT_SYSTEM_FOREGROUND, Native.EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, _proc, 0, 0, Native.WINEVENT_OUTOFCONTEXT);
        OnForeground(IntPtr.Zero, 0, Native.GetForegroundWindow(), 0, 0, 0, 0);
    }

    void OnForeground(IntPtr hook, uint type, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        if (hwnd == IntPtr.Zero || Native.ProcessId(hwnd) == Environment.ProcessId) return;
        var cls = Native.ClassName(hwnd);
        if (cls is "Shell_TrayWnd" or "Shell_SecondaryTrayWnd" or "NotifyIconOverflowWindow" or "TopLevelWindowForOverflowXamlIsland") return;
        LastOtherWindow = hwnd;
    }

    public void Dispose()
    {
        if (_hook != IntPtr.Zero) Native.UnhookWinEvent(_hook);
        _hook = IntPtr.Zero;
    }
}
