using System.Diagnostics;
using System.Windows.Forms;
using WisprFaux.Core.Settings;
using WisprFaux.Platform;
using WisprFaux.Services;
using WisprFaux.UI;

namespace WisprFaux;

/// <summary>
/// The system tray icon and its menu, the counterpart of the Mac app's menu bar item. Wispr
/// Faux has no main window: everything starts here.
/// </summary>
sealed class TrayApp : ApplicationContext
{
    readonly DictationController _controller;
    readonly NotifyIcon _tray;
    readonly ContextMenuStrip _menu = new();
    SettingsForm? _settingsForm;

    public TrayApp(AppSettings settings, bool firstRun, bool background)
    {
        _controller = new DictationController(settings);
        _tray = new NotifyIcon
        {
            Icon = TrayIcons.Idle,
            Text = "Wispr Faux",
            ContextMenuStrip = _menu,
            Visible = true,
        };
        _menu.Opening += (_, e) =>
        {
            BuildMenu();
            e.Cancel = false;
        };
        _tray.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) ShowSettings();
        };
        _controller.Changed += UpdateIcon;
        BuildMenu();
        _controller.Start();
        UpdateIcon();

        if (_controller.HookError is { } error)
            _tray.ShowBalloonTip(10_000, "Wispr Faux can't see the keyboard", error, ToolTipIcon.Error);
        else if (!_controller.Transcription.Model.IsDownloaded)
        {
            _tray.ShowBalloonTip(10_000, "Wispr Faux needs its speech model",
                $"Open Settings from the tray icon and click Download ({_controller.Transcription.Model.SizeText}).", ToolTipIcon.Info);
            if (firstRun || !background) ShowSettings();
        }
        else if (firstRun || !background)
        {
            _tray.ShowBalloonTip(5_000, "Wispr Faux is running",
                $"Hold {_controller.TriggerDescription}, speak, and let go. The text appears where your cursor is.", ToolTipIcon.Info);
        }
    }

    void UpdateIcon()
    {
        var t = _controller.Transcription;
        var needsAttention = _controller.HookError is not null
            || t.Status is TranscriptionService.Phase.NotDownloaded or TranscriptionService.Phase.Failed;
        _tray.Icon = _controller.CurrentState switch
        {
            DictationController.State.Recording => TrayIcons.Recording,
            DictationController.State.Transcribing or DictationController.State.Inserting => TrayIcons.Working,
            _ => needsAttention ? TrayIcons.Attention : TrayIcons.Idle,
        };
        var text = $"Wispr Faux: {StatusLine()}";
        _tray.Text = text.Length > 127 ? text[..127] : text;
    }

    string StatusLine()
    {
        if (_controller.HookError is not null) return "keyboard hook failed (see the log)";
        var t = _controller.Transcription;
        return t.Status switch
        {
            TranscriptionService.Phase.Ready => $"hold {_controller.TriggerDescription} to dictate",
            _ => t.StatusText,
        };
    }

    void BuildMenu()
    {
        _menu.Items.Clear();
        _menu.Items.Add(new ToolStripMenuItem(StatusLine()) { Enabled = false });
        var t = _controller.Transcription;
        if (t.Status is TranscriptionService.Phase.NotDownloaded || (t.Status is TranscriptionService.Phase.Failed && !t.Model.IsDownloaded))
            _menu.Items.Add($"Download speech model ({t.Model.SizeText})", null, async (_, _) => await t.DownloadAsync(_controller.Settings.UseGpu));
        if (_controller.Cleanup.StatusLine is { } cleanup)
            _menu.Items.Add(new ToolStripMenuItem("Cleanup: " + cleanup) { Enabled = false });
        _menu.Items.Add(new ToolStripSeparator());

        var latest = _controller.History.Latest;
        _menu.Items.Add(new ToolStripMenuItem("Paste Last Transcript", null, async (_, _) => await _controller.PasteLastAsync()) { Enabled = latest is not null });
        _menu.Items.Add(new ToolStripMenuItem("Copy Last Transcript", null, (_, _) => { if (latest is not null) _controller.Copy(latest); }) { Enabled = latest is not null });
        var recent = new ToolStripMenuItem("Recent");
        foreach (var record in _controller.History.All.Take(20))
        {
            var label = record.Text.Replace('\n', ' ');
            if (label.Length > 60) label = label[..57] + "…";
            recent.DropDownItems.Add(new ToolStripMenuItem(label, null, (_, _) => _controller.Copy(record))
            {
                ToolTipText = $"{record.Date.LocalDateTime:g}{(record.AppName is null ? "" : " · " + record.AppName)}. Click to copy",
            });
        }
        if (recent.DropDownItems.Count > 0)
        {
            recent.DropDownItems.Add(new ToolStripSeparator());
            recent.DropDownItems.Add("Clear History", null, (_, _) => _controller.ClearHistory());
        }
        else recent.Enabled = false;
        _menu.Items.Add(recent);
        _menu.Items.Add(new ToolStripSeparator());

        _menu.Items.Add("Settings…", null, (_, _) => ShowSettings());
        _menu.Items.Add(new ToolStripMenuItem("Open at Sign-in", null, (_, _) => ToggleStartup()) { Checked = StartupManager.IsEnabled });
        if (_controller.LastTiming is { } timing)
            _menu.Items.Add(new ToolStripMenuItem("Last: " + timing) { Enabled = false });
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add("Quit Wispr Faux", null, (_, _) => ExitThread());
    }

    void ToggleStartup()
    {
        try { StartupManager.SetEnabled(!StartupManager.IsEnabled); }
        catch (Exception e) { MessageBox.Show(e.Message, "Wispr Faux"); }
    }

    public void ShowSettings()
    {
        if (_settingsForm is { IsDisposed: false })
        {
            _settingsForm.WindowState = FormWindowState.Normal;
            _settingsForm.Activate();
            return;
        }
        _settingsForm = new SettingsForm(_controller);
        _settingsForm.FormClosed += (_, _) => _settingsForm = null;
        _settingsForm.Show();
        _settingsForm.Activate();
    }

    protected override void ExitThreadCore()
    {
        Log.Info("App", "Quitting");
        _settingsForm?.Close();
        _tray.Visible = false;
        _controller.Dispose();
        _tray.Dispose();
        base.ExitThreadCore();
    }
}
