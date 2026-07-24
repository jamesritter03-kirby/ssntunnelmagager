using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace RemoteStuff.Services;

/// <summary>
/// Crash-safe backups of unsaved editor buffers, mirroring the macOS app's
/// <c>EditorBackupStore</c>. Backups are small JSON files under
/// <c>Application Support/RemoteStuff/EditorBackups</c>; a backup exists only
/// while a buffer has unsaved changes, so anything left behind after a crash is
/// offered for restore on the next launch.
/// </summary>
public static class EditorBackupStore
{
    private static string Dir
    {
        get
        {
            var d = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "RemoteStuff", "EditorBackups");
            Directory.CreateDirectory(d);
            return d;
        }
    }

    /// <summary>A snapshot of an unsaved editor buffer.</summary>
    public sealed class Backup
    {
        public string Id { get; set; } = "";
        public string Title { get; set; } = "";
        public string? FilePath { get; set; }
        public string Text { get; set; } = "";
        public string Language { get; set; } = "Plain Text";
        public string LineEnding { get; set; } = "LF";
        public string Encoding { get; set; } = "UTF-8";
        public DateTime SavedAt { get; set; }
    }

    private static readonly JsonSerializerOptions Options = new() { WriteIndented = false };

    /// <summary>Write (or overwrite) the backup for a buffer. Best-effort.</summary>
    public static void Save(Backup b)
    {
        try
        {
            b.SavedAt = DateTime.UtcNow;
            File.WriteAllText(Path.Combine(Dir, b.Id + ".json"),
                JsonSerializer.Serialize(b, Options));
        }
        catch { /* best-effort */ }
    }

    /// <summary>Remove a buffer's backup (called when it is saved or its tab closes).</summary>
    public static void Delete(string id)
    {
        try
        {
            var p = Path.Combine(Dir, id + ".json");
            if (File.Exists(p)) File.Delete(p);
        }
        catch { /* best-effort */ }
    }

    /// <summary>Load every stored backup, newest first.</summary>
    public static IReadOnlyList<Backup> LoadAll()
    {
        var list = new List<Backup>();
        try
        {
            foreach (var f in Directory.EnumerateFiles(Dir, "*.json"))
            {
                try
                {
                    var b = JsonSerializer.Deserialize<Backup>(File.ReadAllText(f));
                    if (b != null && !string.IsNullOrEmpty(b.Id)) list.Add(b);
                }
                catch { /* skip corrupt entry */ }
            }
        }
        catch { /* best-effort */ }
        list.Sort((a, b) => b.SavedAt.CompareTo(a.SavedAt));
        return list;
    }
}
