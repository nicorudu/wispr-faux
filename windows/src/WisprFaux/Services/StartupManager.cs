using Microsoft.Win32;

namespace WisprFaux.Services;

/// <summary>
/// Start at sign-in: a value under HKCU\Software\Microsoft\Windows\CurrentVersion\Run, which
/// Windows also lists in Settings → Apps → Startup and Task Manager → Startup apps (where it can
/// be turned off too).
/// </summary>
static class StartupManager
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string ValueName = "Wispr Faux";

    static string Command => $"\"{Environment.ProcessPath}\" --background";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string value && value.Contains(Environment.ProcessPath ?? "\0", StringComparison.OrdinalIgnoreCase);
        }
    }

    public static void SetEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled) key.SetValue(ValueName, Command);
        else key.DeleteValue(ValueName, throwOnMissingValue: false);
    }
}
