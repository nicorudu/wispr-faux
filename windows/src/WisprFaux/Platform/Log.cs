namespace WisprFaux.Platform;

/// <summary>
/// A small log file in %LOCALAPPDATA%\Wispr Faux\Logs. Records timings, lengths, app names and
/// errors: never what was said, never clipboard contents.
/// </summary>
static class Log
{
    static readonly object Lock = new();
    static readonly string FilePath = Path.Combine(Core.Settings.AppPaths.Logs, "wisprfaux.log");
    const long MaxBytes = 1_000_000;

    public static string Folder => Core.Settings.AppPaths.Logs;
    public static string File => FilePath;

    public static void Info(string category, string message) => Write("INFO", category, message);
    public static void Error(string category, string message) => Write("ERROR", category, message);

    static void Write(string level, string category, string message)
    {
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {level,-5} [{category}] {message}{Environment.NewLine}";
        System.Diagnostics.Debug.Write(line);
        lock (Lock)
        {
            try
            {
                Directory.CreateDirectory(Folder);
                var info = new FileInfo(FilePath);
                if (info.Exists && info.Length > MaxBytes)
                    System.IO.File.Move(FilePath, FilePath + ".1", overwrite: true);
                System.IO.File.AppendAllText(FilePath, line);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
