using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using CommunityToolkit.Mvvm.ComponentModel;

namespace RemoteStuff.ViewModels;

/// <summary>Which klogg-style tool the editor's log panel is showing.</summary>
public enum LogToolsTab { Filter, Search, Marks, Highlighters }

/// <summary>One line shown in a filter / search / marks result list, carrying its
/// 1-based source line number so a click can jump to it in the editor.</summary>
public sealed class LogResultLine
{
    public int LineNumber { get; init; }
    public string Text { get; init; } = "";

    /// <summary>"123  the line text" style display used by the list template.</summary>
    public string Display => $"{LineNumber,6}  {Text}";
}

/// <summary>A user-defined highlighter (klogg): every match of <see cref="Pattern"/>
/// is coloured with <see cref="ColorHex"/> (or the whole matching line when
/// <see cref="WholeLine"/>). Observable so edits in the panel re-render live.</summary>
public sealed partial class LogHighlighterVm : ObservableObject
{
    [ObservableProperty] private string _pattern = "";
    [ObservableProperty] private string _colorHex = "#FFF3A3";
    [ObservableProperty] private bool _caseSensitive;
    [ObservableProperty] private bool _wholeLine;
    [ObservableProperty] private bool _enabled = true;

    /// <summary>Raised on any property change so the view can re-render + persist.</summary>
    public event Action? Changed;

    partial void OnPatternChanged(string value) => Changed?.Invoke();
    partial void OnColorHexChanged(string value) => Changed?.Invoke();
    partial void OnCaseSensitiveChanged(bool value) => Changed?.Invoke();
    partial void OnWholeLineChanged(bool value) => Changed?.Invoke();
    partial void OnEnabledChanged(bool value) => Changed?.Invoke();

    /// <summary>A palette of pleasant, readable highlight backgrounds.</summary>
    public static readonly string[] Palette =
    {
        "#FFF3A3", "#B7E4C7", "#A9D6FF", "#FFC9C9", "#E4C1F9",
        "#FFD8A8", "#C3FAE8", "#D0BFFF", "#FFEC99", "#B2F2BB",
    };
}

/// <summary>Plain DTO for persisting a highlighter to disk.</summary>
public sealed class LogHighlighterDto
{
    public string Pattern { get; set; } = "";
    public string ColorHex { get; set; } = "#FFF3A3";
    public bool CaseSensitive { get; set; }
    public bool WholeLine { get; set; }
    public bool Enabled { get; set; } = true;
}

/// <summary>App-wide persistence of the user's highlighters (shared by every editor
/// tab), stored as one small JSON file under Application Support/RemoteStuff.</summary>
public static class LogHighlighterStore
{
    private static string FilePath
    {
        get
        {
            var d = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "RemoteStuff");
            Directory.CreateDirectory(d);
            return Path.Combine(d, "log-highlighters.json");
        }
    }

    private static readonly JsonSerializerOptions Options = new() { WriteIndented = false };

    public static List<LogHighlighterDto> Load()
    {
        try
        {
            if (!File.Exists(FilePath)) return new();
            var json = File.ReadAllText(FilePath);
            return JsonSerializer.Deserialize<List<LogHighlighterDto>>(json) ?? new();
        }
        catch { return new(); }
    }

    public static void Save(IEnumerable<LogHighlighterDto> list)
    {
        try { File.WriteAllText(FilePath, JsonSerializer.Serialize(list, Options)); }
        catch { /* best-effort */ }
    }
}
