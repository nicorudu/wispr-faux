using WisprFaux.Core.Hotkey;
using Xunit;

namespace WisprFaux.Core.Tests;

public class ShortcutMatcherTests
{
    static KeyInput Down(int vk, int scan = 0) => new(KeyKind.KeyDown, vk, scan);
    static KeyInput Up(int vk) => new(KeyKind.KeyUp, vk);
    static readonly KeyInput Click = new(KeyKind.MouseDown, 0);

    static ShortcutMatcher Default() => new(HotkeyTriggers.Default);

    [Fact]
    public void HoldAndReleaseControl()
    {
        var m = Default();
        var down = m.Handle(Down(VK.LControl));
        Assert.False(down.Swallow); // Ctrl still reaches apps.
        Assert.Equal(new[] { HotkeyEvent.PushToTalkPressed }, down.Events);
        // Windows repeats the key-down while it's held.
        Assert.Empty(m.Handle(Down(VK.LControl)).Events);
        Assert.Empty(m.Handle(Down(VK.LControl)).Events);
        var up = m.Handle(Up(VK.LControl));
        Assert.Equal(new[] { HotkeyEvent.PushToTalkReleased }, up.Events);
        Assert.Equal(ShortcutMatcher.Phase.Idle, m.CurrentPhase);
    }

    [Fact]
    public void RightControlWorksToo()
    {
        var m = Default();
        Assert.Equal(new[] { HotkeyEvent.PushToTalkPressed }, m.Handle(Down(VK.RControl)).Events);
        Assert.Empty(m.Handle(Up(VK.LControl)).Events); // Not the held one.
        Assert.Equal(new[] { HotkeyEvent.PushToTalkReleased }, m.Handle(Up(VK.RControl)).Events);
    }

    [Fact]
    public void OrdinaryTypingPassesThroughWhenIdle()
    {
        var m = Default();
        foreach (var vk in new[] { 0x41, VK.Space, VK.Escape, VK.Return })
        {
            Assert.Equal(Decision.Pass, m.Handle(Down(vk)));
            Assert.Equal(Decision.Pass, m.Handle(Up(vk)));
        }
    }

    [Fact]
    public void ControlSpaceLocksHandsFreeAndNextControlStops()
    {
        var m = Default();
        m.Handle(Down(VK.LControl));
        var space = m.Handle(Down(VK.Space));
        Assert.True(space.Swallow);
        Assert.Equal(new[] { HotkeyEvent.HandsFreeToggled }, space.Events);
        Assert.True(m.Handle(Down(VK.Space)).Swallow); // Autorepeat.
        Assert.True(m.Handle(Up(VK.Space)).Swallow);
        Assert.Empty(m.Handle(Up(VK.LControl)).Events); // Keeps listening.
        Assert.Equal(ShortcutMatcher.Phase.HandsFree, m.CurrentPhase);
        Assert.Equal(new[] { HotkeyEvent.PushToTalkReleased }, m.Handle(Down(VK.RControl)).Events);
        Assert.Empty(m.Handle(Up(VK.RControl)).Events);
        Assert.Equal(ShortcutMatcher.Phase.Idle, m.CurrentPhase);
    }

    [Fact]
    public void EscapeCancelsAndIsSwallowed()
    {
        var m = Default();
        m.Handle(Down(VK.LControl));
        var esc = m.Handle(Down(VK.Escape));
        Assert.True(esc.Swallow);
        Assert.Equal(new[] { HotkeyEvent.Cancel }, esc.Events);
        Assert.True(m.Handle(Up(VK.Escape)).Swallow);
        Assert.Empty(m.Handle(Up(VK.LControl)).Events); // Release after a cancel is ignored.
    }

    [Fact]
    public void EscapeCancelsOnceWhileTheAppIsBusy()
    {
        var m = Default();
        m.EscapeCancels = true;
        Assert.Equal(new[] { HotkeyEvent.Cancel }, m.Handle(Down(VK.Escape)).Events);
        m.Handle(Up(VK.Escape));
        Assert.Equal(Decision.Pass, m.Handle(Down(VK.Escape)));
    }

    [Fact]
    public void ControlShortcutCancelsAndPassesThrough()
    {
        var m = Default();
        m.Handle(Down(VK.LControl));
        var c = m.Handle(Down(0x43));
        Assert.False(c.Swallow);
        Assert.Equal(new[] { HotkeyEvent.Cancel }, c.Events);
        Assert.Empty(m.Handle(Up(VK.LControl)).Events);
    }

    [Fact]
    public void OtherModifiersDontCancelButTheNextKeyDoes()
    {
        var m = Default();
        m.Handle(Down(VK.LControl));
        Assert.Equal(Decision.Pass, m.Handle(Down(VK.LShift)));
        Assert.Equal(ShortcutMatcher.Phase.Holding, m.CurrentPhase);
        Assert.Equal(new[] { HotkeyEvent.Cancel }, m.Handle(Down(0x54)).Events);
    }

    [Fact]
    public void CtrlClickCancelsButClicksOutsideAHoldDont()
    {
        var m = Default();
        Assert.Equal(Decision.Pass, m.Handle(Click));
        m.Handle(Down(VK.LControl));
        Assert.Equal(new[] { HotkeyEvent.Cancel }, m.Handle(Click).Events);

        m.Handle(Up(VK.LControl));
        m.Handle(Down(VK.LControl));
        m.Handle(Down(VK.Space));
        Assert.Equal(Decision.Pass, m.Handle(Click)); // Hands-free: clicking a field is fine.
    }

    [Fact]
    public void AltGrsFakeControlIsIgnored()
    {
        var m = Default();
        Assert.Equal(Decision.Pass, m.Handle(Down(VK.LControl, ShortcutMatcher.AltGrFakeControlScanCode)));
        Assert.Equal(ShortcutMatcher.Phase.Idle, m.CurrentPhase);
    }

    [Fact]
    public void RightAltCanBeTheTrigger()
    {
        var m = new ShortcutMatcher(new HashSet<HotkeyTrigger> { HotkeyTrigger.RightAlt });
        Assert.Equal(Decision.Pass, m.Handle(Down(VK.LControl)));
        Assert.Equal(Decision.Pass, m.Handle(Up(VK.LControl)));
        Assert.Equal(new[] { HotkeyEvent.PushToTalkPressed }, m.Handle(Down(VK.RMenu)).Events);
        Assert.Equal(new[] { HotkeyEvent.PushToTalkReleased }, m.Handle(Up(VK.RMenu)).Events);
    }

    [Fact]
    public void SecondTriggerWhileHoldingIsIgnored()
    {
        var m = Default();
        m.Handle(Down(VK.LControl));
        Assert.Equal(Decision.Pass, m.Handle(Down(VK.RControl)));
        Assert.Empty(m.Handle(Up(VK.RControl)).Events);
        Assert.Equal(new[] { HotkeyEvent.PushToTalkReleased }, m.Handle(Up(VK.LControl)).Events);
    }

    [Fact]
    public void ResyncReleasesAMissedKeyUp()
    {
        var m = Default();
        m.Handle(Down(VK.LControl));
        Assert.Empty(m.Resync(_ => true));
        Assert.Equal(new[] { HotkeyEvent.PushToTalkReleased }, m.Resync(_ => false));
        Assert.Null(m.HeldTrigger);
    }

    [Fact]
    public void ResyncKeepsHandsFreeRunning()
    {
        var m = Default();
        m.Handle(Down(VK.LControl));
        m.Handle(Down(VK.Space));
        Assert.Empty(m.Resync(_ => false));
        Assert.Equal(ShortcutMatcher.Phase.HandsFree, m.CurrentPhase);
    }

    [Fact]
    public void RemovingTheHeldTriggerCancels()
    {
        var m = Default();
        m.Handle(Down(VK.LControl));
        Assert.Equal(new[] { HotkeyEvent.Cancel }, m.SetTriggers(new HashSet<HotkeyTrigger> { HotkeyTrigger.RightAlt }));
        Assert.Equal(ShortcutMatcher.Phase.Idle, m.CurrentPhase);
    }

    [Fact]
    public void DescribesTriggers()
    {
        Assert.Equal("Ctrl", HotkeyTriggers.Describe(HotkeyTriggers.Default));
        Assert.Equal("Right Ctrl or Right Alt (AltGr)", HotkeyTriggers.Describe(new HashSet<HotkeyTrigger> { HotkeyTrigger.RightAlt, HotkeyTrigger.RightControl }));
    }
}
