using System.Windows.Forms;
using LLama.Native;
using WisprFaux.Core.Settings;
using WisprFaux.Platform;

namespace WisprFaux;

static class Program
{
    const string MutexName = @"Local\WisprFaux.SingleInstance";
    const string ShowEventName = @"Local\WisprFaux.ShowSettings";
    const string QuitEventName = @"Local\WisprFaux.Quit";

    /// <summary>
    /// WisprFaux.exe               start (or open Settings in the running copy)
    /// WisprFaux.exe --background  start quietly (used at sign-in)
    /// WisprFaux.exe --quit        ask the running copy to quit, and wait for it
    /// </summary>
    [STAThread]
    static int Main(string[] args)
    {
        if (args.Contains("--quit", StringComparer.OrdinalIgnoreCase)) return QuitRunningCopy();
        var background = args.Contains("--background", StringComparer.OrdinalIgnoreCase);

        // Only one copy may run: two would both react to the hotkey.
        using var mutex = new Mutex(true, MutexName, out var isFirst);
        if (!isFirst)
        {
            if (!background && EventWaitHandle.TryOpenExisting(ShowEventName, out var show)) show.Set();
            return 0;
        }

        var firstRun = !File.Exists(AppPaths.Settings);
        var settings = AppSettings.Load();
        settings.Save();

        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.ThreadException += (_, e) => Log.Error("App", "Unhandled: " + e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Error("App", "Unhandled: " + e.ExceptionObject);
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            Log.Error("App", "Unobserved: " + e.Exception);
            e.SetObserved();
        };

        // llama.cpp's library is chosen once, before first use: Vulkan (GPU) when allowed and
        // available, otherwise the best CPU build for this processor.
        try
        {
            NativeLibraryConfig.All.WithVulkan(settings.UseGpu).WithCuda(false).WithAutoFallback(true);
        }
        catch (Exception e) { Log.Error("Cleanup", "llama.cpp configuration failed: " + e.Message); }

        Log.Info("App", $"Wispr Faux {Application.ProductVersion} starting{(background ? " at sign-in" : "")}");
        var app = new TrayApp(settings, firstRun, background);

        using var showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
        using var quitEvent = new EventWaitHandle(false, EventResetMode.AutoReset, QuitEventName);
        var ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        var waiter = new Thread(() =>
        {
            var handles = new WaitHandle[] { showEvent, quitEvent };
            while (true)
            {
                var which = WaitHandle.WaitAny(handles);
                if (which == 0) ui.Post(_ => app.ShowSettings(), null);
                else
                {
                    ui.Post(_ => app.ExitThread(), null);
                    return;
                }
            }
        }) { IsBackground = true, Name = "Wispr Faux signals" };
        waiter.Start();

        Application.Run(app);
        return 0;
    }

    /// <summary>Used by install.ps1: quits the running copy cleanly so its clipboard backup is put back.</summary>
    static int QuitRunningCopy()
    {
        if (!EventWaitHandle.TryOpenExisting(QuitEventName, out var quit)) return 0;
        quit.Set();
        for (var i = 0; i < 100; i++)
        {
            if (!Mutex.TryOpenExisting(MutexName, out var m)) return 0;
            m.Dispose();
            Thread.Sleep(100);
        }
        return 1;
    }
}
