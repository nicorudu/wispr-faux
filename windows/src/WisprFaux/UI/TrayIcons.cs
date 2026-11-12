using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace WisprFaux.UI;

/// <summary>
/// The tray icons, drawn at startup: a white microphone on a coloured disc, so it reads on
/// both light and dark taskbars. Grey when idle, red while listening, amber while working,
/// with a slash when something needs attention.
/// </summary>
static class TrayIcons
{
    public static readonly Icon Idle = Make(Color.FromArgb(90, 90, 96), slash: false);
    public static readonly Icon Recording = Make(Color.FromArgb(232, 52, 44), slash: false);
    public static readonly Icon Working = Make(Color.FromArgb(214, 140, 0), slash: false);
    public static readonly Icon Attention = Make(Color.FromArgb(90, 90, 96), slash: true);

    [DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr handle);

    static Icon Make(Color disc, bool slash)
    {
        const int size = 64;
        using var bitmap = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using var discBrush = new SolidBrush(disc);
            g.FillEllipse(discBrush, 1, 1, size - 2, size - 2);

            using var white = new SolidBrush(Color.White);
            using var pen = new Pen(Color.White, 5) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            // Capsule.
            using (var capsule = new GraphicsPath())
            {
                var r = new RectangleF(23, 10, 18, 30);
                capsule.AddArc(r.X, r.Y, r.Width, r.Width, 180, 180);
                capsule.AddArc(r.X, r.Bottom - r.Width, r.Width, r.Width, 0, 180);
                capsule.CloseFigure();
                g.FillPath(white, capsule);
            }
            // Cradle and stand.
            g.DrawArc(pen, 15, 18, 34, 30, 0, 180);
            g.DrawLine(pen, 32, 48, 32, 55);
            if (slash)
            {
                using var cut = new Pen(disc, 9) { StartCap = LineCap.Round, EndCap = LineCap.Round };
                g.DrawLine(cut, 14, 12, 50, 52);
                g.DrawLine(pen, 14, 12, 50, 52);
            }
        }
        var handle = bitmap.GetHicon();
        var icon = (Icon)Icon.FromHandle(handle).Clone();
        DestroyIcon(handle);
        return icon;
    }
}
