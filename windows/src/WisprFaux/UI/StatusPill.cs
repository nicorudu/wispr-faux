using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using WisprFaux.Platform;

namespace WisprFaux.UI;

/// <summary>What the pill shows.</summary>
sealed record PillContent(PillContent.Kind What, string Text, bool IsWarning = false, bool HandsFree = false)
{
    public enum Kind { Listening, Working, Notice }

    public static PillContent Listening(bool handsFree, string trigger) =>
        new(Kind.Listening, handsFree ? $"Listening (hands-free, press {trigger} to stop)" : "Listening", HandsFree: handsFree);
    public static PillContent Working(string text) => new(Kind.Working, text);
    public static PillContent Notice(string text, bool warning) => new(Kind.Notice, text, warning);
}

/// <summary>
/// The small pill at the bottom of the screen: Listening with a level meter, Transcribing, or a
/// short notice. It must never take focus, or Ctrl+V would land in Wispr Faux itself: it's a
/// no-activate, click-through tool window that is shown without activation.
/// </summary>
sealed class StatusPill : Form
{
    readonly System.Windows.Forms.Timer _meterTimer = new() { Interval = 50 };
    PillContent? _content;
    Func<float>? _level;
    float _shownLevel;
    int _spinner;

    public StatusPill()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        BackColor = Color.FromArgb(28, 28, 30);
        ForeColor = Color.White;
        DoubleBuffered = true;
        Font = new Font("Segoe UI", 10f, FontStyle.Regular);
        // Makes it a layered window, which together with WS_EX_TRANSPARENT lets clicks through.
        Opacity = 0.96;
        _meterTimer.Tick += (_, _) =>
        {
            _shownLevel = Math.Max(_level?.Invoke() ?? 0, _shownLevel * 0.8f);
            _spinner++;
            Invalidate();
        };
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW | Native.WS_EX_TOPMOST | Native.WS_EX_TRANSPARENT;
            return cp;
        }
    }

    // Never activate, even when clicked.
    protected override void WndProc(ref Message m)
    {
        const int WM_MOUSEACTIVATE = 0x21, MA_NOACTIVATE = 3;
        if (m.Msg == WM_MOUSEACTIVATE)
        {
            m.Result = (IntPtr)MA_NOACTIVATE;
            return;
        }
        base.WndProc(ref m);
    }

    /// <summary>Shows <paramref name="content"/>, or hides the pill when it's null.</summary>
    public void Show(PillContent? content, Func<float> level)
    {
        _content = content;
        _level = level;
        if (content is null)
        {
            _meterTimer.Stop();
            if (Visible) Hide();
            return;
        }
        _meterTimer.Enabled = content.What is PillContent.Kind.Listening or PillContent.Kind.Working;
        Place(content);
        if (!Visible) base.Show();
        Invalidate();
    }

    float UiScale => DeviceDpi / 96f;

    void Place(PillContent content)
    {
        var s = UiScale;
        var textSize = TextRenderer.MeasureText(content.Text, Font);
        var meter = content.What == PillContent.Kind.Listening ? (int)(46 * s) : (int)(24 * s);
        var width = (int)(28 * s) + meter + textSize.Width;
        var height = (int)(38 * s);
        var screen = Screen.FromPoint(Cursor.Position).WorkingArea;
        var maxWidth = screen.Width - (int)(40 * s);
        width = Math.Min(width, maxWidth);
        Bounds = new Rectangle(screen.Left + (screen.Width - width) / 2, screen.Bottom - height - (int)(56 * s), width, height);
        using var path = Rounded(new Rectangle(0, 0, width, height), height / 2);
        Region = new Region(path);
        if (IsHandleCreated)
        {
            var round = Native.DWMWCP_ROUND;
            Native.DwmSetWindowAttribute(Handle, Native.DWMWA_WINDOW_CORNER_PREFERENCE, ref round, sizeof(int));
        }
    }

    static GraphicsPath Rounded(Rectangle r, int radius)
    {
        var path = new GraphicsPath();
        var d = radius * 2;
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        if (_content is not { } content) return;
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var s = UiScale;
        var x = (int)(14 * s);
        var mid = Height / 2;

        switch (content.What)
        {
            case PillContent.Kind.Listening:
            {
                // A red dot and five bars that follow the microphone level.
                using var red = new SolidBrush(Color.FromArgb(255, 69, 58));
                var dot = 9 * s;
                g.FillEllipse(red, x, mid - dot / 2, dot, dot);
                using var bar = new SolidBrush(Color.White);
                var bx = x + 16 * s;
                float[] shape = { 0.5f, 0.8f, 1f, 0.8f, 0.5f };
                for (var i = 0; i < shape.Length; i++)
                {
                    var h = Math.Max(3 * s, 18 * s * shape[i] * _shownLevel);
                    g.FillRectangle(bar, bx + i * 5 * s, mid - h / 2, 3 * s, h);
                }
                x += (int)(46 * s);
                break;
            }
            case PillContent.Kind.Working:
            {
                // Three dots taking turns.
                for (var i = 0; i < 3; i++)
                {
                    var on = (_spinner / 4) % 3 == i;
                    using var brush = new SolidBrush(on ? Color.White : Color.FromArgb(110, 255, 255, 255));
                    var d = 5 * s;
                    g.FillEllipse(brush, x + i * 7 * s, mid - d / 2, d, d);
                }
                x += (int)(24 * s);
                break;
            }
            default:
            {
                using var brush = new SolidBrush(content.IsWarning ? Color.FromArgb(255, 214, 10) : Color.FromArgb(48, 209, 88));
                var d = 8 * s;
                g.FillEllipse(brush, x, mid - d / 2, d, d);
                x += (int)(24 * s);
                break;
            }
        }
        var textRect = new Rectangle(x, 0, Width - x - (int)(14 * s), Height);
        TextRenderer.DrawText(g, content.Text, Font, textRect, ForeColor,
            TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _meterTimer.Dispose();
        base.Dispose(disposing);
    }
}
