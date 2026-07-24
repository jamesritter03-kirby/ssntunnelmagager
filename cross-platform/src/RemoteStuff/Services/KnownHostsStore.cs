using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace RemoteStuff.Services;

/// <summary>One entry (line) in <c>~/.ssh/known_hosts</c>.</summary>
public sealed class KnownHostEntry
{
    public required string RawLine { get; init; }
    public required string HostLabel { get; init; }
    public required string KeyType { get; init; }
    public bool IsHashed { get; init; }
}

/// <summary>
/// Reads and edits <c>~/.ssh/known_hosts</c> so a changed/stale host key can be
/// removed from inside the app. A cross-platform port of the macOS store.
/// </summary>
public sealed class KnownHostsStore
{
    public static string Path =>
        System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".ssh", "known_hosts");

    public bool FileExists => File.Exists(Path);
    public string? ErrorMessage { get; private set; }
    public List<KnownHostEntry> Entries { get; private set; } = new();

    public void Reload()
    {
        ErrorMessage = null;
        if (!FileExists) { Entries = new(); return; }
        try
        {
            Entries = Parse(File.ReadAllText(Path));
        }
        catch
        {
            Entries = new();
            ErrorMessage = "Couldn't read ~/.ssh/known_hosts.";
        }
    }

    /// <summary>Parse known_hosts text into per-line entries (blank/comment lines skipped).</summary>
    public static List<KnownHostEntry> Parse(string text)
    {
        var result = new List<KnownHostEntry>();
        foreach (var raw in text.Split(new[] { '\n', '\r' }))
        {
            var trimmed = raw.Trim();
            if (trimmed.Length == 0 || trimmed.StartsWith("#")) continue;
            var fields = trimmed.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length < 2) continue;

            var hostField = fields[0];
            var keyType = fields[1];
            if (hostField.StartsWith("@") && fields.Length >= 3)
            {
                hostField = fields[1];
                keyType = fields[2];
            }

            var isHashed = hostField.StartsWith("|");
            var hostLabel = isHashed
                ? "Hashed host"
                : string.Join(", ", hostField.Split(',').Select(PrettyHost));
            result.Add(new KnownHostEntry
            {
                RawLine = raw,
                HostLabel = hostLabel,
                KeyType = keyType,
                IsHashed = isHashed
            });
        }
        return result;
    }

    /// <summary>Strip the <c>[host]:port</c> brackets ssh uses for non-standard ports.</summary>
    private static string PrettyHost(string token)
    {
        if (token.StartsWith("[") && token.Contains(']'))
        {
            var close = token.IndexOf(']');
            var host = token[1..close];
            var after = token[(close + 1)..];
            var port = after.StartsWith(":") ? after[1..] : "";
            return port.Length == 0 ? host : $"{host}:{port}";
        }
        return token;
    }

    public void Remove(KnownHostEntry entry) => Rewrite(new[] { entry });
    public void Remove(IEnumerable<KnownHostEntry> entries) => Rewrite(entries);

    private void Rewrite(IEnumerable<KnownHostEntry> toRemove)
    {
        if (!FileExists) return;
        try
        {
            var text = File.ReadAllText(Path);
            var doomed = toRemove.Select(e => e.RawLine).ToHashSet();
            var kept = text.Split('\n').Where(line => !doomed.Contains(line.TrimEnd('\r')) && !doomed.Contains(line));
            File.WriteAllText(Path, string.Join("\n", kept));
            Reload();
        }
        catch (Exception ex)
        {
            ErrorMessage = "Couldn't update known_hosts: " + ex.Message;
        }
    }
}
