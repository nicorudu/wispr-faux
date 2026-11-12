using System.Text.Json;

namespace WisprFaux.Core.History;

public sealed record TranscriptRecord(
    string Text,
    DateTimeOffset Date,
    string? AppName = null,
    // The transcript before stumble cleanup, when cleanup changed it.
    string? Original = null);

/// <summary>The last <c>capacity</c> transcripts, newest first, kept in a JSON file. No audio.</summary>
public sealed class HistoryStore
{
    readonly int _capacity;
    readonly string _path;
    readonly object _lock = new();
    List<TranscriptRecord> _records;

    static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    public HistoryStore(string path, int capacity = 100)
    {
        _path = path;
        _capacity = capacity;
        _records = Load(path);
        if (_records.Count > capacity) _records.RemoveRange(capacity, _records.Count - capacity);
    }

    public IReadOnlyList<TranscriptRecord> All
    {
        get { lock (_lock) return _records.ToArray(); }
    }

    public TranscriptRecord? Latest
    {
        get { lock (_lock) return _records.Count > 0 ? _records[0] : null; }
    }

    public void Add(TranscriptRecord record)
    {
        lock (_lock)
        {
            _records.Insert(0, record);
            if (_records.Count > _capacity) _records.RemoveRange(_capacity, _records.Count - _capacity);
            Save();
        }
    }

    public void Clear()
    {
        lock (_lock)
        {
            _records.Clear();
            Save();
        }
    }

    static List<TranscriptRecord> Load(string path)
    {
        try
        {
            if (File.Exists(path))
                return JsonSerializer.Deserialize<List<TranscriptRecord>>(File.ReadAllText(path)) ?? new();
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { }
        return new();
    }

    void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var temp = _path + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(_records, Json));
            File.Move(temp, _path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
