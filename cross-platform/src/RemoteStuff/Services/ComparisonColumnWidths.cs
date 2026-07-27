using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace RemoteStuff.Services;

/// <summary>
/// Remembers the user's per-column widths for the Compare &amp; Bulk Edit table
/// across launches. Keyed by column name ("Profile", "Host" and each field name).
/// A cross-platform port of the macOS <c>ComparisonColumnWidths</c>.
/// </summary>
public sealed class ComparisonColumnWidths
{
    private const double MinWidth = 70;
    private const double MaxWidth = 640;

    private readonly string _path;
    private Dictionary<string, double> _widths = new();

    public ComparisonColumnWidths()
    {
        var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (string.IsNullOrEmpty(baseDir))
            baseDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
        var dir = Path.Combine(baseDir, "RemoteStuff");
        Directory.CreateDirectory(dir);
        _path = Path.Combine(dir, "compare-column-widths.json");
        Load();
    }

    /// <summary>The default width for a column when the user hasn't resized it.</summary>
    public static double DefaultWidth(string key) => key switch
    {
        "Profile" => 190,
        "Host" => 160,
        _ => 120,
    };

    public double WidthFor(string key) =>
        _widths.TryGetValue(key, out var w) ? w : DefaultWidth(key);

    public void Set(double width, string key) =>
        _widths[key] = Math.Min(Math.Max(width, MinWidth), MaxWidth);

    public bool HasCustom => _widths.Count > 0;

    public void Reset()
    {
        _widths.Clear();
        Save();
    }

    private void Load()
    {
        try
        {
            if (File.Exists(_path))
                _widths = JsonSerializer.Deserialize<Dictionary<string, double>>(File.ReadAllText(_path)) ?? new();
        }
        catch { _widths = new(); }
    }

    public void Save()
    {
        try
        {
            var tmp = _path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(_widths));
            File.Move(tmp, _path, overwrite: true);
        }
        catch { /* best effort */ }
    }
}
