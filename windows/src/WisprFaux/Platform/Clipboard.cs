using System.Runtime.InteropServices;
using System.Text;

namespace WisprFaux.Platform;

/// <summary>
/// The Win32 clipboard, used directly (not through WinForms' OLE clipboard) so every format can
/// be backed up byte for byte and put back exactly.
/// </summary>
static class Win32Clipboard
{
    static System.Windows.Forms.NativeWindow? _owner;

    /// <summary>
    /// A hidden message-only window that owns the clipboard while Wispr Faux writes to it:
    /// SetClipboardData fails after EmptyClipboard when the clipboard was opened without a
    /// window. Created on first use, on the UI thread.
    /// </summary>
    static IntPtr Owner
    {
        get
        {
            if (_owner is null)
            {
                _owner = new System.Windows.Forms.NativeWindow();
                _owner.CreateHandle(new System.Windows.Forms.CreateParams { Caption = "Wispr Faux clipboard", Parent = new IntPtr(-3) /* HWND_MESSAGE */ });
            }
            return _owner.Handle;
        }
    }

    static readonly uint ExcludeFromMonitoring = Native.RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing");
    static readonly uint CanIncludeInHistory = Native.RegisterClipboardFormat("CanIncludeInClipboardHistory");
    static readonly uint CanUploadToCloud = Native.RegisterClipboardFormat("CanUploadToCloudClipboard");
    static readonly uint ViewerIgnore = Native.RegisterClipboardFormat("Clipboard Viewer Ignore");

    /// <summary>Opens the clipboard, retrying while another app holds it.</summary>
    public static bool Open(IntPtr owner = default)
    {
        if (owner == IntPtr.Zero) owner = Owner;
        for (var attempt = 0; attempt < 20; attempt++)
        {
            if (Native.OpenClipboard(owner)) return true;
            Thread.Sleep(10);
        }
        return false;
    }

    /// <summary>
    /// Writes plain text. <paramref name="transient"/> marks it so Windows clipboard history
    /// (Win+V), cloud clipboard and clipboard managers skip it: the Windows counterpart of
    /// macOS's org.nspasteboard.TransientType.
    /// </summary>
    public static bool SetText(string text, bool transient, IntPtr owner = default)
    {
        if (!Open(owner)) return false;
        try
        {
            Native.EmptyClipboard();
            var bytes = Encoding.Unicode.GetBytes(text + "\0");
            if (!SetBytes(Native.CF_UNICODETEXT, bytes)) return false;
            if (transient) MarkTransient();
            return true;
        }
        finally { Native.CloseClipboard(); }
    }

    /// <summary>Must be called while the clipboard is open.</summary>
    internal static void MarkTransient()
    {
        SetBytes(ExcludeFromMonitoring, new byte[] { 0 });
        SetBytes(CanIncludeInHistory, BitConverter.GetBytes(0));
        SetBytes(CanUploadToCloud, BitConverter.GetBytes(0));
        SetBytes(ViewerIgnore, new byte[] { 0 });
    }

    /// <summary>Puts a copy of <paramref name="bytes"/> on the open clipboard.</summary>
    internal static bool SetBytes(uint format, byte[] bytes)
    {
        var handle = Native.GlobalAlloc(Native.GMEM_MOVEABLE, (UIntPtr)Math.Max(bytes.Length, 1));
        if (handle == IntPtr.Zero) return false;
        var target = Native.GlobalLock(handle);
        if (target == IntPtr.Zero)
        {
            Native.GlobalFree(handle);
            return false;
        }
        Marshal.Copy(bytes, 0, target, bytes.Length);
        Native.GlobalUnlock(handle);
        if (Native.SetClipboardData(format, handle) != IntPtr.Zero) return true;
        Native.GlobalFree(handle);
        return false;
    }

    /// <summary>Reads a memory-backed format from the open clipboard, or null.</summary>
    internal static byte[]? GetBytes(uint format, long limit)
    {
        var handle = Native.GetClipboardData(format);
        if (handle == IntPtr.Zero) return null;
        var size = (long)(ulong)Native.GlobalSize(handle);
        if (size <= 0 || size > limit) return null;
        var source = Native.GlobalLock(handle);
        if (source == IntPtr.Zero) return null;
        try
        {
            var bytes = new byte[size];
            Marshal.Copy(source, bytes, 0, (int)size);
            return bytes;
        }
        finally { Native.GlobalUnlock(handle); }
    }
}

/// <summary>
/// Every format on the clipboard, copied, so it can be put back after a paste: text, rich text,
/// HTML, images (DIB), file lists and app-specific formats. Formats held as GDI objects
/// (CF_BITMAP, metafiles, palettes) are skipped; Windows rebuilds CF_BITMAP from the DIB.
/// </summary>
sealed class ClipboardSnapshot
{
    /// <summary>Formats bigger than this aren't kept (a huge copied image or spreadsheet).</summary>
    const long PerFormatLimit = 64L * 1024 * 1024;
    const long TotalLimit = 128L * 1024 * 1024;

    readonly List<(uint Format, byte[] Data)> _items;
    public int FormatCount => _items.Count;
    public long ByteCount => _items.Sum(i => (long)i.Data.Length);
    public int SkippedFormats { get; }

    ClipboardSnapshot(List<(uint, byte[])> items, int skipped)
    {
        _items = items;
        SkippedFormats = skipped;
    }

    public static ClipboardSnapshot Capture(IntPtr owner = default)
    {
        var items = new List<(uint, byte[])>();
        var skipped = 0;
        if (!Win32Clipboard.Open(owner)) return new ClipboardSnapshot(items, 0);
        try
        {
            long total = 0;
            uint format = 0;
            while ((format = Native.EnumClipboardFormats(format)) != 0)
            {
                if (IsGdiFormat(format) || IsOleFormat(format)) { skipped++; continue; }
                var data = Win32Clipboard.GetBytes(format, Math.Min(PerFormatLimit, TotalLimit - total));
                if (data is null) { skipped++; continue; }
                total += data.Length;
                items.Add((format, data));
            }
        }
        finally { Native.CloseClipboard(); }
        return new ClipboardSnapshot(items, skipped);
    }

    /// <summary>
    /// OLE's bookkeeping formats point at the copying app's live data object; put back later,
    /// they can confuse OLE-based paste. Windows rebuilds them from the other formats.
    /// </summary>
    static readonly HashSet<string> OleFormats = new(StringComparer.OrdinalIgnoreCase)
    {
        "DataObject", "Ole Private Data", "OleClipboardPersistOnFlush",
    };

    static bool IsOleFormat(uint format)
    {
        if (format < 0xC000) return false; // Registered formats start at 0xC000.
        var name = new System.Text.StringBuilder(128);
        return Native.GetClipboardFormatName(format, name, name.Capacity) > 0 && OleFormats.Contains(name.ToString());
    }

    static bool IsGdiFormat(uint format) => format is Native.CF_BITMAP or Native.CF_METAFILEPICT or Native.CF_PALETTE
        or Native.CF_ENHMETAFILE or Native.CF_OWNERDISPLAY or Native.CF_DSPBITMAP or Native.CF_DSPMETAFILEPICT
        or Native.CF_DSPENHMETAFILE
        || (format >= Native.CF_PRIVATEFIRST && format <= Native.CF_GDIOBJLAST);

    /// <summary>
    /// Puts everything back. Marked so clipboard history doesn't record the user's own copy a
    /// second time.
    /// </summary>
    public bool Restore(IntPtr owner = default)
    {
        if (!Win32Clipboard.Open(owner)) return false;
        try
        {
            Native.EmptyClipboard();
            foreach (var (format, data) in _items) Win32Clipboard.SetBytes(format, data);
            if (_items.Count > 0) Win32Clipboard.MarkTransient();
            return true;
        }
        finally { Native.CloseClipboard(); }
    }
}
