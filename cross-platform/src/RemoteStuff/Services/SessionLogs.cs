using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace RemoteStuff.Services;

/// <summary>One saved session-log file on disk, with the metadata the browser shows.</summary>
public sealed record SavedSessionLog(string Path, string Name, DateTime Modified, long Size);

/// <summary>Shared helpers for the SSH / local terminal session-logging feature:
/// where logs live, how they are named, and the transcript header. The cross-platform
/// counterpart of the macOS app's <c>TerminalSession.logsDirectory</c> plumbing.</summary>
public static class SessionLogs
{
    /// <summary><c>~/…/RemoteStuff/logs</c> — a sibling of <c>profiles.json</c>, created on demand.</summary>
    public static string Directory
    {
        get
        {
            var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            if (string.IsNullOrEmpty(baseDir))
                baseDir = System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
            var dir = System.IO.Path.Combine(baseDir, "RemoteStuff", "logs");
            System.IO.Directory.CreateDirectory(dir);
            return dir;
        }
    }

    /// <summary>Build a timestamped log path for a freshly started session named
    /// <paramref name="title"/> (e.g. <c>prod-server-20260727-143025.log</c>).</summary>
    public static string NewLogPath(string title)
    {
        var safe = string.Join("_", (title ?? "session").Split(System.IO.Path.GetInvalidFileNameChars()))
            .Trim();
        if (safe.Length == 0) safe = "session";
        var stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
        return System.IO.Path.Combine(Directory, $"{safe}-{stamp}.log");
    }

    /// <summary>A short human-readable transcript header written at the top of a new log.</summary>
    public static string Header(string title, string? commandPreview)
    {
        var when = DateTime.Now.ToString("f");
        var cmd = string.IsNullOrWhiteSpace(commandPreview) ? "" : $"# {commandPreview}\n";
        return $"# {title} — {when}\n{cmd}\n";
    }

    /// <summary>All <c>.log</c> files in the logs directory, newest first.</summary>
    public static List<SavedSessionLog> List()
    {
        var result = new List<SavedSessionLog>();
        try
        {
            foreach (var path in System.IO.Directory.EnumerateFiles(Directory, "*.log"))
            {
                var info = new FileInfo(path);
                result.Add(new SavedSessionLog(path, info.Name, info.LastWriteTime, info.Length));
            }
        }
        catch { /* directory unreadable — return what we have */ }
        return result.OrderByDescending(l => l.Modified).ToList();
    }
}
