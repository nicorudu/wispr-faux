using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;
using WisprFaux.Core.Cleanup;
using WisprFaux.Core.Hotkey;
using WisprFaux.Core.Settings;
using WisprFaux.Services;

namespace WisprFaux.UI;

/// <summary>Settings: hotkey, microphone, speech model, stumble cleanup, start at sign-in.</summary>
sealed class SettingsForm : Form
{
    readonly DictationController _controller;
    readonly System.Windows.Forms.Timer _refresh = new() { Interval = 500 };

    // Speech
    readonly ComboBox _model = DropDown(320);
    readonly Label _modelStatus = Note();
    readonly Button _modelDownload = new() { AutoSize = true };
    readonly ComboBox _language = DropDown(200);
    readonly ComboBox _microphone = DropDown(320);
    readonly CheckBox _keepMic = new() { Text = "Keep the microphone ready, so no first words are lost (Windows shows it as in use)", AutoSize = true, MaximumSize = new Size(540, 0) };
    readonly CheckBox _gpu = new() { Text = "Use the graphics card (Vulkan) when there is one", AutoSize = true };

    // Cleanup
    readonly RadioButton _cleanupOff = new() { Text = "Off", AutoSize = true };
    readonly RadioButton _cleanupLocal = new() { Text = "On this PC", AutoSize = true };
    readonly RadioButton _cleanupCloud = new() { Text = "Cloud", AutoSize = true };
    readonly Label _cleanupStatus = Note();
    readonly Button _localDownload = new() { AutoSize = true };
    readonly ComboBox _provider = DropDown(240);
    readonly TextBox _apiKey = new() { UseSystemPasswordChar = true, Width = 260 };
    readonly Button _saveKey = new() { Text = "Save key", AutoSize = true };
    readonly LinkLabel _getKey = new() { Text = "Get a key", AutoSize = true };
    readonly Label _costNote = Note();
    readonly Button _test = new() { Text = "Test", AutoSize = true };
    readonly Label _testResult = Note();
    readonly FlowLayoutPanel _localRow = Row();
    readonly FlowLayoutPanel _cloudRow = Row();
    readonly FlowLayoutPanel _cloudKeyRow = Row();

    // General
    readonly CheckBox _startAtLogin = new() { Text = "Open Wispr Faux when I sign in to Windows", AutoSize = true };
    readonly Dictionary<HotkeyTrigger, CheckBox> _triggers = new();

    bool _updating;

    static readonly (string Code, string Name)[] Languages =
    {
        ("auto", "Detect automatically"), ("en", "English"), ("es", "Spanish"), ("fr", "French"),
        ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("ca", "Catalan"),
        ("pl", "Polish"), ("ru", "Russian"), ("uk", "Ukrainian"), ("tr", "Turkish"), ("ar", "Arabic"),
        ("hi", "Hindi"), ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean"),
    };

    public SettingsForm(DictationController controller)
    {
        _controller = controller;
        Text = "Wispr Faux Settings";
        Icon = TrayIcons.Idle;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = true;
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Font = new Font("Segoe UI", 9.5f);
        Padding = new Padding(12);
        MinimumSize = new Size(600, 0);

        var root = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = false, Location = new Point(12, 12) };
        root.Controls.Add(HotkeySection());
        root.Controls.Add(SpeechSection());
        root.Controls.Add(CleanupSection());
        root.Controls.Add(GeneralSection());
        var close = new Button { Text = "Close", AutoSize = true, DialogResult = DialogResult.Cancel };
        close.Click += (_, _) => Close();
        CancelButton = close;
        var bottom = Row();
        bottom.Anchor = AnchorStyles.Right;
        bottom.Controls.Add(close);
        root.Controls.Add(bottom);
        Controls.Add(root);

        _refresh.Tick += (_, _) => RefreshStatus();
        controller.Changed += OnChanged;
        LoadValues();
        RefreshStatus();
    }

    void OnChanged()
    {
        if (IsHandleCreated && !IsDisposed) BeginInvoke(RefreshStatus);
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        _refresh.Start();
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        _refresh.Stop();
        _controller.Changed -= OnChanged;
        base.OnFormClosed(e);
    }

    // MARK: Sections

    Control HotkeySection()
    {
        var panel = Column();
        panel.Controls.Add(Note("Hold one of these keys to dictate. Ctrl+Space keeps listening hands-free until the next press; Esc cancels."));
        var row = Row();
        foreach (var trigger in Enum.GetValues<HotkeyTrigger>())
        {
            var box = new CheckBox { Text = trigger.DisplayName(), AutoSize = true };
            box.CheckedChanged += (_, _) =>
            {
                if (_updating) return;
                _controller.SetTrigger(trigger, box.Checked);
                LoadValues(); // The last trigger can't be turned off.
            };
            _triggers[trigger] = box;
            row.Controls.Add(box);
        }
        panel.Controls.Add(row);
        return Group("Hold to talk", panel);
    }

    Control SpeechSection()
    {
        var panel = Column();
        foreach (var m in ModelCatalog.Whisper) _model.Items.Add($"{m.DisplayName}, {m.SizeText}: {m.Note}");
        _model.SelectedIndexChanged += (_, _) =>
        {
            if (_updating || _model.SelectedIndex < 0) return;
            _controller.SetWhisperModel(ModelCatalog.Whisper[_model.SelectedIndex]);
            RefreshStatus();
        };
        _modelDownload.Click += async (_, _) => await _controller.Transcription.DownloadAsync(_controller.Settings.UseGpu);
        panel.Controls.Add(Labeled("Model", _model));
        var statusRow = Row();
        statusRow.Controls.Add(_modelStatus);
        statusRow.Controls.Add(_modelDownload);
        panel.Controls.Add(statusRow);

        foreach (var (_, name) in Languages) _language.Items.Add(name);
        _language.SelectedIndexChanged += (_, _) =>
        {
            if (_updating || _language.SelectedIndex < 0) return;
            _controller.Settings.Language = Languages[_language.SelectedIndex].Code;
            _controller.Settings.Save();
        };
        panel.Controls.Add(Labeled("Language", _language));

        _microphone.DropDown += (_, _) => LoadMicrophones();
        _microphone.SelectedIndexChanged += (_, _) =>
        {
            if (_updating || _microphone.SelectedItem is not MicItem item) return;
            _controller.Settings.MicrophoneDevice = item.Number;
            _controller.Settings.MicrophoneName = item.Number < 0 ? null : item.Name;
            _controller.Settings.Save();
            _controller.ApplyMicrophoneSettings();
        };
        panel.Controls.Add(Labeled("Microphone", _microphone));
        _keepMic.CheckedChanged += (_, _) =>
        {
            if (_updating) return;
            _controller.Settings.KeepMicrophoneReady = _keepMic.Checked;
            _controller.Settings.Save();
            _controller.ApplyMicrophoneSettings();
        };
        panel.Controls.Add(_keepMic);

        _gpu.CheckedChanged += (_, _) =>
        {
            if (_updating) return;
            _controller.Settings.UseGpu = _gpu.Checked;
            _controller.Settings.Save();
            MessageBox.Show(this, "Quit and reopen Wispr Faux for this to take effect.", "Wispr Faux", MessageBoxButtons.OK, MessageBoxIcon.Information);
        };
        panel.Controls.Add(_gpu);
        return Group("Speech to text (on this PC, with whisper.cpp)", panel);
    }

    sealed record MicItem(int Number, string Name)
    {
        public override string ToString() => Name;
    }

    void LoadMicrophones()
    {
        _updating = true;
        _microphone.Items.Clear();
        _microphone.Items.Add(new MicItem(-1, "Windows default microphone"));
        foreach (var (number, name) in AudioRecorder.Devices()) _microphone.Items.Add(new MicItem(number, name));
        var current = _controller.Settings.MicrophoneDevice < 0 ? -1
            : AudioRecorder.Resolve(_controller.Settings.MicrophoneDevice, _controller.Settings.MicrophoneName);
        _microphone.SelectedItem = _microphone.Items.Cast<MicItem>().FirstOrDefault(i => i.Number == current) ?? _microphone.Items[0];
        _updating = false;
    }

    Control CleanupSection()
    {
        var panel = Column();
        panel.Controls.Add(Note("Fixes stumbles before pasting: “um”, repeated words, “Tuesday, no wait, Wednesday”. Only dictations with a stumble go to the model; anything odd in its reply and the text is pasted as spoken."));
        var modes = Row();
        modes.Controls.AddRange(new Control[] { _cleanupOff, _cleanupLocal, _cleanupCloud });
        panel.Controls.Add(modes);
        void Mode(RadioButton button, CleanupMode mode) => button.CheckedChanged += (_, _) =>
        {
            if (_updating || !button.Checked) return;
            _controller.Cleanup.SetMode(mode);
            RefreshStatus();
        };
        Mode(_cleanupOff, CleanupMode.Off);
        Mode(_cleanupLocal, CleanupMode.OnDevice);
        Mode(_cleanupCloud, CleanupMode.Cloud);

        _localDownload.Click += async (_, _) => await _controller.Cleanup.DownloadLocalModelAsync();
        _localRow.Controls.Add(_localDownload);
        panel.Controls.Add(_localRow);

        foreach (var p in CloudProvider.All) _provider.Items.Add(p.DisplayName);
        _provider.SelectedIndexChanged += (_, _) =>
        {
            if (_updating || _provider.SelectedIndex < 0) return;
            _controller.Cleanup.SetProvider(CloudProvider.All[_provider.SelectedIndex]);
            _apiKey.Text = "";
            RefreshStatus();
        };
        _cloudRow.Controls.Add(_provider);
        _cloudRow.Controls.Add(_getKey);
        _cloudRow.Controls.Add(_costNote);
        _getKey.LinkClicked += (_, _) => _controller.Cleanup.OpenKeysPage();
        panel.Controls.Add(_cloudRow);
        _apiKey.PlaceholderText = "Paste the API key";
        _saveKey.Click += (_, _) =>
        {
            _controller.Cleanup.SaveCloudKey(_apiKey.Text);
            _apiKey.Text = "";
            RefreshStatus();
        };
        _cloudKeyRow.Controls.Add(_apiKey);
        _cloudKeyRow.Controls.Add(_saveKey);
        panel.Controls.Add(_cloudKeyRow);

        panel.Controls.Add(_cleanupStatus);
        var testRow = Row();
        _test.Click += async (_, _) => await _controller.Cleanup.TestAsync();
        testRow.Controls.Add(_test);
        testRow.Controls.Add(_testResult);
        panel.Controls.Add(testRow);
        panel.Controls.Add(Note("Cloud: only the text of dictations with a stumble is sent; audio never leaves this PC. Both providers are in China, and free tiers may use requests for training. Keys are encrypted for your Windows account."));
        return Group("Clean up stumbles", panel);
    }

    Control GeneralSection()
    {
        var panel = Column();
        _startAtLogin.CheckedChanged += (_, _) =>
        {
            if (_updating) return;
            try { StartupManager.SetEnabled(_startAtLogin.Checked); }
            catch (Exception e) { MessageBox.Show(this, e.Message, "Wispr Faux"); }
        };
        panel.Controls.Add(_startAtLogin);
        var links = Row();
        var data = new LinkLabel { Text = "Open the data folder", AutoSize = true };
        data.LinkClicked += (_, _) => Open(AppPaths.Root);
        var log = new LinkLabel { Text = "Open the log", AutoSize = true };
        log.LinkClicked += (_, _) => Open(Platform.Log.File);
        var mic = new LinkLabel { Text = "Windows microphone privacy settings", AutoSize = true };
        mic.LinkClicked += (_, _) => Open(MicrophonePrivacy.SettingsUri);
        links.Controls.AddRange(new Control[] { data, log, mic });
        panel.Controls.Add(links);
        return Group("General", panel);
    }

    static void Open(string target)
    {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); }
        catch (Exception) { }
    }

    // MARK: Values

    void LoadValues()
    {
        _updating = true;
        var s = _controller.Settings;
        foreach (var (trigger, box) in _triggers) box.Checked = s.Triggers.Contains(trigger);
        _model.SelectedIndex = ModelCatalog.Whisper.ToList().IndexOf(ModelCatalog.WhisperNamed(s.WhisperModel));
        var language = Array.FindIndex(Languages, l => l.Code == s.Language);
        _language.SelectedIndex = language < 0 ? 0 : language;
        _gpu.Checked = s.UseGpu;
        _keepMic.Checked = s.KeepMicrophoneReady;
        _startAtLogin.Checked = StartupManager.IsEnabled;
        _cleanupOff.Checked = _controller.Cleanup.Mode == CleanupMode.Off;
        _cleanupLocal.Checked = _controller.Cleanup.Mode == CleanupMode.OnDevice;
        _cleanupCloud.Checked = _controller.Cleanup.Mode == CleanupMode.Cloud;
        _provider.SelectedIndex = CloudProvider.All.ToList().IndexOf(_controller.Cleanup.Provider);
        _updating = false;
        LoadMicrophones();
    }

    void RefreshStatus()
    {
        var t = _controller.Transcription;
        _modelStatus.Text = t.StatusText;
        _modelDownload.Text = $"Download ({t.Model.SizeText})";
        _modelDownload.Visible = t.Status is TranscriptionService.Phase.NotDownloaded
            || (t.Status is TranscriptionService.Phase.Failed && !t.Model.IsDownloaded);

        var c = _controller.Cleanup;
        _localRow.Visible = c.Mode == CleanupMode.OnDevice
            && c.LocalStatus is CleanupService.LocalPhase.NotDownloaded or CleanupService.LocalPhase.Failed
            && !c.LocalModel.IsDownloaded;
        _localDownload.Text = $"Download {c.LocalModel.DisplayName} ({c.LocalModel.SizeText})";
        _cloudRow.Visible = _cloudKeyRow.Visible = c.Mode == CleanupMode.Cloud;
        _costNote.Text = c.Provider.CostNote;
        _apiKey.PlaceholderText = c.HasCloudKey ? "Key saved. Paste a new one to replace it" : "Paste the API key";
        _cleanupStatus.Text = c.StatusLine ?? "";
        _cleanupStatus.Visible = c.StatusLine is not null;
        _test.Visible = _testResult.Visible = c.Mode != CleanupMode.Off;
        _test.Enabled = !c.IsTesting;
        _testResult.Text = c.TestResult ?? "";
    }

    // MARK: Layout helpers

    /// <summary>A bold heading with the section's controls under it.</summary>
    static Control Group(string title, Control content)
    {
        var section = Column();
        section.Margin = new Padding(0, 0, 0, 14);
        section.Controls.Add(new Label { Text = title, AutoSize = true, Font = new Font("Segoe UI Semibold", 10.5f), Margin = new Padding(0, 0, 0, 4) });
        content.Margin = new Padding(12, 0, 0, 0);
        section.Controls.Add(content);
        return section;
    }

    static FlowLayoutPanel Column() => new() { FlowDirection = FlowDirection.TopDown, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = false, Margin = new Padding(0) };
    static FlowLayoutPanel Row() => new() { FlowDirection = FlowDirection.LeftToRight, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = false, Margin = new Padding(0) };

    static Control Labeled(string label, Control control)
    {
        var row = Row();
        row.Controls.Add(new Label { Text = label, AutoSize = false, Width = 90, TextAlign = ContentAlignment.MiddleLeft, Height = control.Height });
        row.Controls.Add(control);
        return row;
    }

    static ComboBox DropDown(int width) => new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = width };

    static Label Note(string text = "") => new() { Text = text, AutoSize = true, MaximumSize = new Size(540, 0), ForeColor = SystemColors.GrayText };
}
