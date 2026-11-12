namespace WisprFaux.Core.Hotkey;

/// <summary>Windows virtual-key codes the matcher cares about.</summary>
public static class VK
{
    public const int Back = 0x08, Tab = 0x09, Return = 0x0D, Shift = 0x10, Control = 0x11, Menu = 0x12,
        Capital = 0x14, Escape = 0x1B, Space = 0x20, LWin = 0x5B, RWin = 0x5C,
        LShift = 0xA0, RShift = 0xA1, LControl = 0xA2, RControl = 0xA3, LMenu = 0xA4, RMenu = 0xA5,
        V = 0x56;

    /// <summary>
    /// Keys that only modify other keys. Pressing one while the trigger is held doesn't end
    /// the dictation (it may be the start of Ctrl+Shift+…); the next real key does.
    /// </summary>
    public static bool IsModifier(int vk) => vk is Shift or Control or Menu or Capital or LWin or RWin
        or LShift or RShift or LControl or RControl or LMenu or RMenu;
}

/// <summary>A key the user can hold to dictate.</summary>
public enum HotkeyTrigger
{
    LeftControl,
    RightControl,
    RightAlt,
}

public static class HotkeyTriggers
{
    /// <summary>Holding either Control key dictates, as on the Mac.</summary>
    public static readonly IReadOnlySet<HotkeyTrigger> Default = new HashSet<HotkeyTrigger> { HotkeyTrigger.LeftControl, HotkeyTrigger.RightControl };

    public static int VirtualKey(this HotkeyTrigger trigger) => trigger switch
    {
        HotkeyTrigger.LeftControl => VK.LControl,
        HotkeyTrigger.RightControl => VK.RControl,
        HotkeyTrigger.RightAlt => VK.RMenu,
        _ => throw new ArgumentOutOfRangeException(nameof(trigger)),
    };

    public static string DisplayName(this HotkeyTrigger trigger) => trigger switch
    {
        HotkeyTrigger.LeftControl => "Left Ctrl",
        HotkeyTrigger.RightControl => "Right Ctrl",
        HotkeyTrigger.RightAlt => "Right Alt (AltGr)",
        _ => trigger.ToString(),
    };

    /// <summary>Plain-language name of a set of triggers, e.g. "Ctrl or Right Alt (AltGr)".</summary>
    public static string Describe(IReadOnlySet<HotkeyTrigger> triggers)
    {
        var names = new List<string>();
        if (triggers.Contains(HotkeyTrigger.LeftControl) && triggers.Contains(HotkeyTrigger.RightControl)) names.Add("Ctrl");
        else
        {
            if (triggers.Contains(HotkeyTrigger.LeftControl)) names.Add(HotkeyTrigger.LeftControl.DisplayName());
            if (triggers.Contains(HotkeyTrigger.RightControl)) names.Add(HotkeyTrigger.RightControl.DisplayName());
        }
        if (triggers.Contains(HotkeyTrigger.RightAlt)) names.Add(HotkeyTrigger.RightAlt.DisplayName());
        return string.Join(" or ", names);
    }
}

public enum HotkeyEvent
{
    PushToTalkPressed,
    PushToTalkReleased,
    HandsFreeToggled,
    Cancel,
}

public enum KeyKind
{
    KeyDown,
    KeyUp,
    /// <summary>Any mouse button went down. Only used to spot Ctrl-click.</summary>
    MouseDown,
}

/// <summary>The parts of a low-level keyboard or mouse event the matcher needs.</summary>
public readonly record struct KeyInput(KeyKind Kind, int VirtualKey, int ScanCode = 0);

public readonly record struct Decision(bool Swallow, IReadOnlyList<HotkeyEvent> Events)
{
    public static readonly Decision Pass = new(false, Array.Empty<HotkeyEvent>());
    public static Decision Of(bool swallow, params HotkeyEvent[] events) => new(swallow, events);
}

/// <summary>
/// Turns raw key events from the low-level keyboard hook into <see cref="HotkeyEvent"/>s and
/// decides which events to swallow. A port of the Mac app's ShortcutMatcher.
///
/// Gestures:
/// - Hold a trigger → PushToTalkPressed; release it → PushToTalkReleased.
/// - Trigger + Space → HandsFreeToggled; recording continues after the trigger is released, and
///   the next trigger press ends it with PushToTalkReleased.
/// - Esc during a session → Cancel (Esc is only swallowed while a session is active). While
///   <see cref="EscapeCancels"/> is set (the app is still transcribing), Esc also cancels.
/// - Any other key or a mouse click while the trigger is held means it's being used as a
///   modifier (Ctrl+C, Ctrl-click…) → Cancel, and the event passes through.
///
/// Trigger keys themselves always pass through, so Ctrl keeps working as Ctrl.
/// Runs inside the hook callback, so every call is O(1).
/// </summary>
public sealed class ShortcutMatcher
{
    public enum Phase { Idle, Holding, HandsFree }

    /// <summary>The scan code Windows gives the fake Left Ctrl it sends along with AltGr.</summary>
    public const int AltGrFakeControlScanCode = 0x21D;

    public IReadOnlySet<HotkeyTrigger> Triggers { get; private set; }
    public Phase CurrentPhase { get; private set; } = Phase.Idle;
    /// <summary>
    /// The trigger that is physically held, as far as the events tell us. Tracked apart from
    /// the phase so the release after a cancel or a hands-free stop is ignored.
    /// </summary>
    public HotkeyTrigger? HeldTrigger { get; private set; }
    /// <summary>Keys whose key-down was swallowed; their autorepeats and key-up are swallowed too.</summary>
    readonly HashSet<int> _swallowedKeys = new();

    /// <summary>
    /// Set by the app after the trigger is released, while it's still working on the dictation:
    /// the next Esc sends Cancel (and is swallowed) even though no key is held. Clears itself
    /// after one Esc, so a second Esc reaches the app as usual.
    /// </summary>
    public bool EscapeCancels { get; set; }

    public ShortcutMatcher(IReadOnlySet<HotkeyTrigger> triggers) => Triggers = triggers;

    public Decision Handle(KeyInput input) => input.Kind switch
    {
        KeyKind.KeyDown => HandleKeyDown(input),
        KeyKind.KeyUp => HandleKeyUp(input),
        KeyKind.MouseDown => HandleMouseDown(),
        _ => Decision.Pass,
    };

    /// <summary>Replaces the enabled triggers. Ends any session whose trigger was removed.</summary>
    public IReadOnlyList<HotkeyEvent> SetTriggers(IReadOnlySet<HotkeyTrigger> triggers)
    {
        Triggers = triggers;
        if (HeldTrigger is { } held && !triggers.Contains(held)) return Reset();
        return Array.Empty<HotkeyEvent>();
    }

    /// <summary>Forgets all state, e.g. when the hook stops. Cancels a session in progress.</summary>
    public IReadOnlyList<HotkeyEvent> Reset()
    {
        var wasActive = CurrentPhase != Phase.Idle;
        CurrentPhase = Phase.Idle;
        HeldTrigger = null;
        _swallowedKeys.Clear();
        return wasActive ? new[] { HotkeyEvent.Cancel } : Array.Empty<HotkeyEvent>();
    }

    /// <summary>
    /// Called periodically while a trigger is held, in case its key-up was never seen (Windows
    /// doesn't send it to hooks when the secure desktop, e.g. a UAC prompt, comes up). Ends a
    /// hold whose trigger is no longer physically down.
    /// </summary>
    public IReadOnlyList<HotkeyEvent> Resync(Func<HotkeyTrigger, bool> isPhysicallyDown)
    {
        if (HeldTrigger is not { } held || isPhysicallyDown(held)) return Array.Empty<HotkeyEvent>();
        HeldTrigger = null;
        _swallowedKeys.Clear();
        if (CurrentPhase != Phase.Holding) return Array.Empty<HotkeyEvent>();
        CurrentPhase = Phase.Idle;
        return new[] { HotkeyEvent.PushToTalkReleased };
    }

    HotkeyTrigger? TriggerFor(KeyInput input)
    {
        // AltGr also sends a fake Left Ctrl; that's not the user holding Ctrl.
        if (input.VirtualKey == VK.LControl && input.ScanCode == AltGrFakeControlScanCode) return null;
        foreach (var trigger in Triggers)
            if (trigger.VirtualKey() == input.VirtualKey) return trigger;
        return null;
    }

    Decision HandleKeyDown(KeyInput input)
    {
        if (TriggerFor(input) is { } trigger)
        {
            // Windows repeats key-downs while a key is held; only the first counts.
            if (HeldTrigger == trigger) return Decision.Pass;
            // A second trigger while one is held is just a modifier; ignore it.
            if (HeldTrigger is not null) return Decision.Pass;
            HeldTrigger = trigger;
            switch (CurrentPhase)
            {
                case Phase.Idle:
                    CurrentPhase = Phase.Holding;
                    return Decision.Of(false, HotkeyEvent.PushToTalkPressed);
                case Phase.HandsFree:
                    CurrentPhase = Phase.Idle;
                    return Decision.Of(false, HotkeyEvent.PushToTalkReleased);
                default:
                    return Decision.Pass;
            }
        }

        var code = input.VirtualKey;
        if (_swallowedKeys.Contains(code)) return Decision.Of(true); // Autorepeat of a swallowed key.

        if (code == VK.Escape && (CurrentPhase != Phase.Idle || EscapeCancels))
        {
            CurrentPhase = Phase.Idle;
            EscapeCancels = false;
            return SwallowKey(code, HotkeyEvent.Cancel);
        }
        if (code == VK.Space && CurrentPhase == Phase.Holding)
        {
            CurrentPhase = Phase.HandsFree;
            return SwallowKey(code, HotkeyEvent.HandsFreeToggled);
        }
        if (VK.IsModifier(code)) return Decision.Pass;
        if (CurrentPhase == Phase.Holding)
        {
            // The trigger is acting as a modifier for this key.
            CurrentPhase = Phase.Idle;
            return Decision.Of(false, HotkeyEvent.Cancel);
        }
        return Decision.Pass;
    }

    Decision HandleKeyUp(KeyInput input)
    {
        if (TriggerFor(input) is { } trigger)
        {
            if (HeldTrigger != trigger) return Decision.Pass;
            HeldTrigger = null;
            if (CurrentPhase != Phase.Holding) return Decision.Pass;
            CurrentPhase = Phase.Idle;
            return Decision.Of(false, HotkeyEvent.PushToTalkReleased);
        }
        return _swallowedKeys.Remove(input.VirtualKey) ? Decision.Of(true) : Decision.Pass;
    }

    /// <summary>A click during a hold is Ctrl-click, never dictation. Clicks during hands-free are fine.</summary>
    Decision HandleMouseDown()
    {
        if (CurrentPhase != Phase.Holding) return Decision.Pass;
        CurrentPhase = Phase.Idle;
        return Decision.Of(false, HotkeyEvent.Cancel);
    }

    Decision SwallowKey(int code, params HotkeyEvent[] events)
    {
        _swallowedKeys.Add(code);
        return Decision.Of(true, events);
    }
}
