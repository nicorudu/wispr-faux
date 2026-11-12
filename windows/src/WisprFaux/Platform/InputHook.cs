using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using WisprFaux.Core.Hotkey;

namespace WisprFaux.Platform;

/// <summary>
/// Low-level keyboard and mouse hooks (WH_KEYBOARD_LL / WH_MOUSE_LL) on a thread of their own,
/// the Windows counterpart of the Mac app's event tap. The callbacks do O(1) work: they hand
/// each key to the <see cref="ShortcutMatcher"/>, swallow what it says to swallow, and queue its
/// events for the controller. Windows removes a hook whose callback is slow, so nothing else
/// ever runs on this thread.
/// </summary>
sealed class InputHook : IDisposable
{
    /// <summary>Marks the keys Wispr Faux sends itself (Ctrl+V), so the hook ignores them.</summary>
    public static readonly UIntPtr SyntheticTag = (UIntPtr)0x57465846; // "WFXF"

    const uint WM_REINSTALL = Native.WM_APP + 1;

    readonly ShortcutMatcher _matcher;
    readonly object _lock = new();
    readonly Channel<HotkeyEvent> _events = Channel.CreateUnbounded<HotkeyEvent>(new UnboundedChannelOptions { SingleReader = true });
    // Kept in fields so the garbage collector never frees a callback Windows still calls.
    readonly Native.LowLevelProc _keyboardProc;
    readonly Native.LowLevelProc _mouseProc;
    Thread? _thread;
    uint _threadId;
    IntPtr _keyboardHook, _mouseHook;
    long _lastCallbackTicks = Environment.TickCount64;
    long _slowCallbacks;

    public InputHook(IReadOnlySet<HotkeyTrigger> triggers)
    {
        _matcher = new ShortcutMatcher(triggers);
        _keyboardProc = KeyboardCallback;
        _mouseProc = MouseCallback;
    }

    public ChannelReader<HotkeyEvent> Events => _events.Reader;
    public bool IsRunning => _keyboardHook != IntPtr.Zero;
    /// <summary>When a hook callback last ran (Environment.TickCount64).</summary>
    public long LastCallbackTicks => Interlocked.Read(ref _lastCallbackTicks);
    public long SlowCallbacks => Interlocked.Read(ref _slowCallbacks);

    public void Start()
    {
        if (_thread is not null) return;
        var ready = new ManualResetEventSlim();
        Exception? failure = null;
        _thread = new Thread(() =>
        {
            _threadId = Native.GetCurrentThreadId();
            try { Install(); }
            catch (Exception e) { failure = e; }
            ready.Set();
            if (failure is not null) return;
            while (Native.GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
            {
                if (msg.hwnd == IntPtr.Zero && msg.message == WM_REINSTALL)
                {
                    Uninstall();
                    try { Install(); }
                    catch (Exception e) { Log.Error("Hotkey", "Reinstalling the hooks failed: " + e.Message); }
                    continue;
                }
                Native.TranslateMessage(ref msg);
                Native.DispatchMessage(ref msg);
            }
            Uninstall();
        })
        {
            IsBackground = true,
            Name = "Wispr Faux input hook",
            Priority = ThreadPriority.Highest,
        };
        _thread.Start();
        ready.Wait();
        if (failure is not null)
        {
            _thread = null;
            throw failure;
        }
        Log.Info("Hotkey", "Keyboard and mouse hooks installed");
    }

    /// <summary>
    /// Puts the hooks back. Windows silently removes a low-level hook whose callback once took
    /// too long; the controller calls this when input happened that the hook never saw.
    /// </summary>
    public void Reinstall()
    {
        if (_threadId != 0) Native.PostThreadMessage(_threadId, WM_REINSTALL, UIntPtr.Zero, IntPtr.Zero);
    }

    void Install()
    {
        var module = Native.GetModuleHandle(null);
        _keyboardHook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, _keyboardProc, module, 0);
        if (_keyboardHook == IntPtr.Zero)
            throw new InvalidOperationException($"SetWindowsHookEx(keyboard) failed: error {Marshal.GetLastWin32Error()}");
        _mouseHook = Native.SetWindowsHookEx(Native.WH_MOUSE_LL, _mouseProc, module, 0);
        if (_mouseHook == IntPtr.Zero)
            Log.Error("Hotkey", $"Mouse hook failed (error {Marshal.GetLastWin32Error()}); Ctrl-click won't cancel");
        Interlocked.Exchange(ref _lastCallbackTicks, Environment.TickCount64);
    }

    void Uninstall()
    {
        if (_keyboardHook != IntPtr.Zero) Native.UnhookWindowsHookEx(_keyboardHook);
        if (_mouseHook != IntPtr.Zero) Native.UnhookWindowsHookEx(_mouseHook);
        _keyboardHook = _mouseHook = IntPtr.Zero;
    }

    public void SetTriggers(IReadOnlySet<HotkeyTrigger> triggers)
    {
        lock (_lock) Publish(_matcher.SetTriggers(triggers));
    }

    /// <summary>While set, the next Esc cancels the dictation being transcribed.</summary>
    public void SetEscapeCancels(bool value)
    {
        lock (_lock) _matcher.EscapeCancels = value;
    }

    public HotkeyTrigger? HeldTrigger
    {
        get { lock (_lock) return _matcher.HeldTrigger; }
    }

    /// <summary>Ends a hold whose key-up the hook missed (e.g. a UAC prompt came up meanwhile).</summary>
    public void Resync()
    {
        lock (_lock)
        {
            if (_matcher.HeldTrigger is not { } held)
            {
                _upPolls = 0;
                return;
            }
            var down = (Native.GetAsyncKeyState(held.VirtualKey()) & 0x8000) != 0;
            _upPolls = down ? 0 : _upPolls + 1;
            // Two polls in a row, so a momentary glitch never cuts a dictation short.
            if (_upPolls >= 2)
            {
                _upPolls = 0;
                Publish(_matcher.Resync(_ => false));
            }
        }
    }

    int _upPolls;

    IntPtr KeyboardCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < 0) return Native.CallNextHookEx(_keyboardHook, nCode, wParam, lParam);
        var started = Stopwatch.GetTimestamp();
        Interlocked.Exchange(ref _lastCallbackTicks, Environment.TickCount64);
        var info = Marshal.PtrToStructure<Native.KBDLLHOOKSTRUCT>(lParam);
        if (info.dwExtraInfo == SyntheticTag) return Native.CallNextHookEx(_keyboardHook, nCode, wParam, lParam);

        var message = (int)wParam;
        var kind = message is Native.WM_KEYDOWN or Native.WM_SYSKEYDOWN ? KeyKind.KeyDown : KeyKind.KeyUp;
        Decision decision;
        lock (_lock)
        {
            // The async key state isn't updated for this event yet: down already means a repeat.
            var repeat = kind == KeyKind.KeyDown && (Native.GetAsyncKeyState((int)info.vkCode) & 0x8000) != 0;
            decision = _matcher.Handle(new KeyInput(kind, (int)info.vkCode, (int)info.scanCode, repeat));
            Publish(decision.Events);
        }
        NoteDuration(started);
        return decision.Swallow ? (IntPtr)1 : Native.CallNextHookEx(_keyboardHook, nCode, wParam, lParam);
    }

    IntPtr MouseCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            Interlocked.Exchange(ref _lastCallbackTicks, Environment.TickCount64);
            var message = (int)wParam;
            if (message is Native.WM_LBUTTONDOWN or Native.WM_RBUTTONDOWN or Native.WM_MBUTTONDOWN or Native.WM_XBUTTONDOWN
                or Native.WM_MOUSEWHEEL or Native.WM_MOUSEHWHEEL)
            {
                lock (_lock) Publish(_matcher.Handle(new KeyInput(KeyKind.MouseDown, 0)).Events);
            }
        }
        return Native.CallNextHookEx(_mouseHook, nCode, wParam, lParam);
    }

    void Publish(IReadOnlyList<HotkeyEvent> events)
    {
        foreach (var e in events) _events.Writer.TryWrite(e);
    }

    void NoteDuration(long started)
    {
        if (Stopwatch.GetElapsedTime(started) > TimeSpan.FromMilliseconds(50)) Interlocked.Increment(ref _slowCallbacks);
    }

    public void Dispose()
    {
        if (_threadId != 0) Native.PostThreadMessage(_threadId, Native.WM_QUIT, UIntPtr.Zero, IntPtr.Zero);
        _thread?.Join(1000);
        _thread = null;
        _events.Writer.TryComplete();
    }
}
