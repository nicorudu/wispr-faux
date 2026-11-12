using System.Diagnostics;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace WisprFaux.Platform;

enum FieldKind
{
    /// <summary>An editable text field or document.</summary>
    Text,
    /// <summary>A password field: never pasted into.</summary>
    Secure,
    /// <summary>Clearly not a text field (a button, a list, the desktop): the text is copied instead.</summary>
    NotText,
    /// <summary>UI Automation couldn't tell (many games and custom-drawn apps): pasted anyway.</summary>
    Unknown,
}

sealed record FieldInfo(FieldKind Kind, char? CharacterBeforeCaret, string? ControlType, string? AppName, uint ProcessId, IntPtr Window);

/// <summary>
/// Reads the focused element through UI Automation, the Windows counterpart of the Mac app's
/// Accessibility reads: is it a text field, is it a password field, and what character comes
/// right before the caret (only that one character is read). Some apps answer UI Automation
/// slowly or not at all, so the read gives up after a short time and says Unknown.
/// </summary>
static class FocusedField
{
    static readonly TimeSpan Timeout = TimeSpan.FromMilliseconds(400);

    public static FieldInfo Read()
    {
        var window = Native.GetForegroundWindow();
        var pid = Native.ProcessId(window);
        var app = AppName(pid);
        FieldInfo result = new(FieldKind.Unknown, null, null, app, pid, window);

        // UI Automation calls block until the target app answers; never let them hold up a paste.
        var thread = new Thread(() =>
        {
            try { result = ReadElement(app, pid, window); }
            // UI Automation turns a provider's error codes into all sorts of exceptions
            // (NotImplementedException, UnauthorizedAccessException…). On this thread any of
            // them would end the app, so every one means "couldn't tell".
            catch (Exception) { }
        }) { IsBackground = true, Name = "Focused field read" };
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
        if (!thread.Join(Timeout)) Log.Info("Paste", $"UI Automation didn't answer within {Timeout.TotalMilliseconds} ms ({app})");
        return result;
    }

    static FieldInfo ReadElement(string? app, uint pid, IntPtr window)
    {
        var element = AutomationElement.FocusedElement;
        if (element is null) return new(FieldKind.Unknown, null, null, app, pid, window);
        var current = element.Current;
        var type = current.ControlType;
        var typeName = type?.ProgrammaticName?.Replace("ControlType.", "");

        if (current.IsPassword) return new(FieldKind.Secure, null, typeName, app, pid, window);

        element.TryGetCurrentPattern(TextPattern.Pattern, out var textObj);
        element.TryGetCurrentPattern(ValuePattern.Pattern, out var valueObj);
        var editableValue = valueObj is ValuePattern value && !value.Current.IsReadOnly;

        FieldKind kind;
        if (type == ControlType.Edit || type == ControlType.Document || textObj is not null || editableValue)
            kind = FieldKind.Text;
        else if (NotTextTypes.Contains(type))
            kind = FieldKind.NotText;
        else
            kind = FieldKind.Unknown;

        char? before = null;
        if (textObj is TextPattern text) before = CharacterBefore(text);
        return new(kind, before, typeName, app, pid, window);
    }

    static readonly HashSet<ControlType?> NotTextTypes = new()
    {
        ControlType.Button, ControlType.CheckBox, ControlType.RadioButton, ControlType.List,
        ControlType.ListItem, ControlType.Tree, ControlType.TreeItem, ControlType.Menu,
        ControlType.MenuItem, ControlType.MenuBar, ControlType.TabItem, ControlType.Hyperlink,
        // Not Table or DataItem: Ctrl+V into a selected spreadsheet cell works.
        ControlType.Image, ControlType.ScrollBar, ControlType.Slider, ControlType.Header, ControlType.HeaderItem, ControlType.SplitButton,
        ControlType.ToolBar, ControlType.TitleBar,
    };

    /// <summary>The one character before the caret (or the selection), or null at the start.</summary>
    static char? CharacterBefore(TextPattern text)
    {
        var selection = text.GetSelection();
        if (selection.Length == 0) return null;
        var range = selection[0].Clone();
        // Collapse to the start of the selection, then reach back one character.
        range.MoveEndpointByRange(TextPatternRangeEndpoint.End, range, TextPatternRangeEndpoint.Start);
        if (range.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, -1) == 0) return null;
        var s = range.GetText(2);
        return string.IsNullOrEmpty(s) ? null : s[^1];
    }

    public static string? AppName(uint pid)
    {
        try
        {
            using var process = Process.GetProcessById((int)pid);
            return process.ProcessName;
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return null;
        }
    }
}
