using System.Diagnostics;
using System.Runtime.InteropServices;
using WisprFaux.Core.Hotkey;

namespace WisprFaux.Platform;

/// <summary>
/// Pastes text into the focused app the way the Mac app does:
/// 1. back up every clipboard format; 2. put the text on the clipboard, marked so clipboard
/// history skips it; 3. press Ctrl+V; 4. put the clipboard back 500 ms after the app has read
/// the text, unless something new was copied meanwhile. A second paste inside that window keeps
/// the original backup.
///
/// The text is offered with delayed rendering, so Wispr Faux knows when the app read it: a slow
/// target (a remote desktop, a busy Word) never gets the old clipboard. If nothing reads it
/// within 5 s, the clipboard is put back anyway.
/// </summary>
sealed class TextInserter
{
    ClipboardSnapshot? _backup;
    uint _ourSequence;
    CancellationTokenSource? _restoreTimer;

    public bool IsInserting { get; private set; }

    /// <summary>Must be called on the UI thread.</summary>
    public async Task InsertAsync(string text, int restoreDelayMs)
    {
        IsInserting = true;
        try
        {
            var watch = Stopwatch.StartNew();
            _restoreTimer?.Cancel();
            // Something was copied since the last paste: that's the clipboard to keep now.
            if (_backup is not null && Native.GetClipboardSequenceNumber() != _ourSequence) _backup = null;
            _backup ??= ClipboardSnapshot.Capture();
            var backupTime = watch.ElapsedMilliseconds;

            var read = Win32Clipboard.OfferText(text)
                ?? throw new InvalidOperationException("the clipboard is in use by another app");
            _ourSequence = Native.GetClipboardSequenceNumber();

            try
            {
                await Task.Delay(10);
                await WaitForModifiersAsync();
                SendCtrlV();
            }
            catch
            {
                RestoreNow(); // Don't leave the user's clipboard replaced.
                throw;
            }
            Log.Info("Paste", $"Pasted {text.Length} characters (backup of {_backup.FormatCount} formats, {_backup.ByteCount} bytes, {_backup.SkippedFormats} skipped, in {backupTime} ms)");

            var timer = new CancellationTokenSource();
            _restoreTimer = timer;
            _ = RestoreLaterAsync(read, restoreDelayMs, timer.Token);
        }
        finally
        {
            IsInserting = false;
        }
    }

    async Task RestoreLaterAsync(Task read, int delayMs, CancellationToken token)
    {
        var watch = Stopwatch.StartNew();
        try
        {
            if (await Task.WhenAny(read, Task.Delay(5000, token)) != read)
                Log.Info("Paste", "Nothing read the pasted text within 5 s; putting the clipboard back");
            else
            {
                // Rendering may count as a clipboard change; it's still Wispr Faux's text.
                _ourSequence = Native.GetClipboardSequenceNumber();
                if (watch.ElapsedMilliseconds > 400) Log.Info("Paste", $"The app read the text after {watch.ElapsedMilliseconds} ms");
            }
            await Task.Delay(delayMs, token);
        }
        catch (TaskCanceledException) { return; }
        if (token.IsCancellationRequested) return;
        RestoreNow();
    }

    /// <summary>Puts the user's clipboard back now (also on quit).</summary>
    public void RestoreNow()
    {
        _restoreTimer?.Cancel();
        var backup = _backup;
        _backup = null;
        if (backup is null) return;
        if (Native.GetClipboardSequenceNumber() != _ourSequence)
        {
            Log.Info("Paste", "Something new was copied after the paste; clipboard left as is");
            return;
        }
        if (!backup.Restore()) Log.Error("Paste", "Couldn't put the clipboard back (another app had it open)");
    }

    /// <summary>
    /// Shift, Alt or Windows still held would turn Ctrl+V into another shortcut; wait up to a
    /// second for them to be let go. Ctrl is fine.
    /// </summary>
    static async Task WaitForModifiersAsync()
    {
        static bool Down(int vk) => (Native.GetAsyncKeyState(vk) & 0x8000) != 0;
        for (var i = 0; i < 50; i++)
        {
            if (!Down(VK.Shift) && !Down(VK.Menu) && !Down(VK.LWin) && !Down(VK.RWin)) return;
            await Task.Delay(20);
        }
        Log.Info("Paste", "Modifier keys still held at paste time");
    }

    /// <summary>
    /// Sends Ctrl+V, tagged so Wispr Faux's own hook ignores it. Apps match shortcuts by virtual
    /// key, and VK_V is the key that types V in every layout (QWERTY, AZERTY, Dvorak…).
    /// </summary>
    public static void SendCtrlV()
    {
        var controlHeld = (Native.GetAsyncKeyState(VK.Control) & 0x8000) != 0;
        var inputs = new List<Native.INPUT>();
        if (!controlHeld) inputs.Add(Key(VK.LControl, down: true));
        inputs.Add(Key(VK.V, down: true));
        inputs.Add(Key(VK.V, down: false));
        if (!controlHeld) inputs.Add(Key(VK.LControl, down: false));
        var sent = Native.SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf<Native.INPUT>());
        if (sent != inputs.Count) throw new InvalidOperationException($"Windows blocked the key presses (error {Marshal.GetLastWin32Error()})");
    }

    /// <summary>
    /// A key that does nothing (VK 0xE8, unassigned), tagged. Sent while Alt is held as the
    /// trigger, so letting go of Alt doesn't open the app's menu bar.
    /// </summary>
    public static void SendMaskKey()
    {
        var inputs = new[] { Key(0xE8, true), Key(0xE8, false) };
        Native.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Native.INPUT>());
    }

    static Native.INPUT Key(int vk, bool down) => new()
    {
        type = Native.INPUT_KEYBOARD,
        U = new Native.InputUnion
        {
            ki = new Native.KEYBDINPUT
            {
                wVk = (ushort)vk,
                wScan = (ushort)Native.MapVirtualKey((uint)vk, 0),
                dwFlags = down ? 0 : Native.KEYEVENTF_KEYUP,
                dwExtraInfo = InputHook.SyntheticTag,
            },
        },
    };
}
