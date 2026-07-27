using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Text.Json;
using RemoteStuff.Models;

namespace RemoteStuff.Services;

/// <summary>
/// App-wide favourite local folders for Finder tabs. A cross-platform port of the
/// macOS <c>FinderBookmarkStore</c> — reuses the <see cref="SftpBookmark"/> model
/// and persists as JSON alongside the profiles and settings.
/// </summary>
public sealed class FinderBookmarkStore
{
    /// <summary>The single shared instance used by every Finder tab.</summary>
    public static FinderBookmarkStore Shared { get; } = new();

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };

    private readonly string _path;

    /// <summary>The saved folders, in the order they were added. Observable so
    /// bookmark menus update live when a folder is added or removed.</summary>
    public ObservableCollection<SftpBookmark> Bookmarks { get; } = new();

    private FinderBookmarkStore()
    {
        var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (string.IsNullOrEmpty(baseDir))
            baseDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
        var dir = Path.Combine(baseDir, "RemoteStuff");
        Directory.CreateDirectory(dir);
        _path = Path.Combine(dir, "finder-bookmarks.json");
        Load();
    }

    /// <summary>True when <paramref name="path"/> is already bookmarked.</summary>
    public bool Contains(string path)
    {
        var p = (path ?? "").Trim();
        return Bookmarks.Any(b => b.TrimmedPath == p);
    }

    /// <summary>Add <paramref name="path"/> (labelled by its last component) unless it's already saved.</summary>
    public void Add(string path)
    {
        var p = (path ?? "").Trim();
        if (p.Length == 0 || Contains(p)) return;
        var last = Path.GetFileName(p.TrimEnd('/', '\\'));
        var label = string.IsNullOrEmpty(last) ? p : last;
        Bookmarks.Add(new SftpBookmark { Label = label, Path = p });
        Save();
    }

    /// <summary>Remove any bookmark pointing at <paramref name="path"/>.</summary>
    public void Remove(string path)
    {
        var p = (path ?? "").Trim();
        var stale = Bookmarks.Where(b => b.TrimmedPath == p).ToList();
        foreach (var b in stale) Bookmarks.Remove(b);
        if (stale.Count > 0) Save();
    }

    private void Load()
    {
        try
        {
            if (!File.Exists(_path)) return;
            var loaded = JsonSerializer.Deserialize<List<SftpBookmark>>(File.ReadAllText(_path), JsonOptions);
            if (loaded == null) return;
            foreach (var b in loaded) Bookmarks.Add(b);
        }
        catch { /* keep empty on any read/parse error */ }
    }

    private void Save()
    {
        try
        {
            var tmp = _path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(Bookmarks.ToList(), JsonOptions));
            File.Move(tmp, _path, overwrite: true);
        }
        catch { /* best-effort */ }
    }
}
