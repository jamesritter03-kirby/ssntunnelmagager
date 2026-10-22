using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using RemoteStuff.Models;

namespace RemoteStuff.Services;

/// <summary>
/// Loads and persists locally-filed feedback (feature requests, bugs, notes) as
/// JSON under the per-user app-data directory, alongside profiles. The user can
/// up-vote items to prioritize them and export the whole list (Markdown or JSON)
/// to hand to the developer.
/// </summary>
public sealed class FeedbackStore
{
    private readonly string _fileURL;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    public List<FeedbackItem> Items { get; private set; } = new();

    public FeedbackStore()
    {
        var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (string.IsNullOrEmpty(baseDir))
            baseDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
        var dir = Path.Combine(baseDir, "RemoteStuff");
        Directory.CreateDirectory(dir);
        _fileURL = Path.Combine(dir, "feedback.json");
        Load();
    }

    private void Load()
    {
        try
        {
            if (File.Exists(_fileURL))
                Items = JsonSerializer.Deserialize<List<FeedbackItem>>(File.ReadAllText(_fileURL), JsonOptions)
                        ?? new List<FeedbackItem>();
        }
        catch
        {
            Items = new List<FeedbackItem>();
        }
    }

    public void Save()
    {
        try
        {
            var tmp = _fileURL + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(Items, JsonOptions));
            File.Move(tmp, _fileURL, overwrite: true);
        }
        catch { /* best-effort */ }
    }

    public FeedbackItem Add(FeedbackKind kind, string title, string details)
    {
        var item = new FeedbackItem
        {
            Kind = kind,
            Title = title.Trim(),
            Details = details.Trim(),
            AppVersion = CurrentVersion(),
            Platform = CurrentPlatform(),
        };
        Items.Add(item);
        Save();
        return item;
    }

    public void Remove(Guid id)
    {
        Items.RemoveAll(i => i.Id == id);
        Save();
    }

    /// <summary>Render the whole list as Markdown, grouped by kind and ordered by
    /// votes, for the user to paste or attach when requesting development.</summary>
    public string ToMarkdown()
    {
        var sb = new StringBuilder();
        sb.AppendLine("# Remote Stuff — Feedback & Feature Requests");
        sb.AppendLine();
        sb.AppendLine($"Exported {DateTime.Now:yyyy-MM-dd HH:mm} · app {CurrentVersion()} · {CurrentPlatform()}");
        sb.AppendLine();

        foreach (var (kind, heading) in new[]
                 {
                     (FeedbackKind.Feature, "Feature Requests"),
                     (FeedbackKind.Bug, "Bugs"),
                     (FeedbackKind.Feedback, "Feedback"),
                 })
        {
            var group = Items.Where(i => i.Kind == kind)
                             .OrderByDescending(i => i.Votes)
                             .ThenBy(i => i.CreatedUtc)
                             .ToList();
            if (group.Count == 0) continue;

            sb.AppendLine($"## {heading}");
            sb.AppendLine();
            foreach (var i in group)
            {
                var title = string.IsNullOrWhiteSpace(i.Title) ? "(untitled)" : i.Title;
                sb.AppendLine($"- **{title}** — {i.Votes} vote{(i.Votes == 1 ? "" : "s")} · {i.Status}");
                if (!string.IsNullOrWhiteSpace(i.Details))
                    foreach (var line in i.Details.Replace("\r\n", "\n").Split('\n'))
                        sb.AppendLine($"  {line}");
                sb.AppendLine($"  _filed {i.CreatedUtc.ToLocalTime():yyyy-MM-dd} · {i.AppVersion} · {i.Platform}_");
                sb.AppendLine();
            }
        }

        if (Items.Count == 0)
            sb.AppendLine("_No items yet._");

        return sb.ToString();
    }

    public string ToJson() => JsonSerializer.Serialize(Items, JsonOptions);

    public static string CurrentVersion()
    {
        var asm = Assembly.GetExecutingAssembly();
        var ver = asm.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
                  ?? asm.GetName().Version?.ToString(3) ?? "?";
        var plus = ver.IndexOf('+');
        return plus >= 0 ? ver[..plus] : ver;
    }

    private static string CurrentPlatform()
    {
        if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX)) return "macOS";
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) return "Windows";
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux)) return "Linux";
        return RuntimeInformation.OSDescription;
    }
}
