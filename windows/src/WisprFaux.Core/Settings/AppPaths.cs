namespace WisprFaux.Core.Settings;

/// <summary>Where Wispr Faux keeps its files: %LOCALAPPDATA%\Wispr Faux.</summary>
public static class AppPaths
{
    public static string Root { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Wispr Faux");

    public static string Models => Path.Combine(Root, "Models");
    public static string Settings => Path.Combine(Root, "settings.json");
    public static string History => Path.Combine(Root, "history.json");
    public static string Logs => Path.Combine(Root, "Logs");
    public static string Secrets => Path.Combine(Root, "Secrets");
}
