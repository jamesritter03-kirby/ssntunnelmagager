using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Services;

namespace RemoteStuff.ViewModels;

/// <summary>One row in the saved-logs browser: the file plus display-friendly text.</summary>
public sealed class SessionLogRow
{
    public SessionLogRow(SavedSessionLog log) => Log = log;
    public SavedSessionLog Log { get; }
    public string Name => Log.Name;
    public string Path => Log.Path;
    public string Subtitle => $"{Log.Modified:g}  ·  {FormatSize(Log.Size)}";

    private static string FormatSize(long bytes) => bytes switch
    {
        < 1024 => $"{bytes} B",
        < 1024 * 1024 => $"{bytes / 1024.0:0.#} KB",
        _ => $"{bytes / (1024.0 * 1024.0):0.#} MB"
    };
}

/// <summary>Backs the "Saved Session Logs" browser window: lists transcript files,
/// previews the selected one, and opens / reveals / deletes them. The cross-platform
/// counterpart of the macOS app's <c>SessionLogsBrowserView</c>.</summary>
public sealed partial class SessionLogsViewModel : ObservableObject
{
    private const int PreviewLimit = 256 * 1024;
    private readonly Action<string> _open;
    private readonly Action<string> _reveal;
    private List<SessionLogRow> _all = new();

    public ObservableCollection<SessionLogRow> Logs { get; } = new();

    [ObservableProperty] private SessionLogRow? _selectedLog;
    [ObservableProperty] private string _preview = "";
    [ObservableProperty] private string _filter = "";

    public bool HasSelection => SelectedLog is not null;
    public string CountLabel => _all.Count == 1 ? "1 log" : $"{_all.Count} logs";

    public SessionLogsViewModel(Action<string> open, Action<string> reveal)
    {
        _open = open;
        _reveal = reveal;
        Reload();
    }

    [RelayCommand]
    private void Reload()
    {
        var keep = SelectedLog?.Path;
        _all = SessionLogs.List().Select(l => new SessionLogRow(l)).ToList();
        ApplyFilter();
        SelectedLog = Logs.FirstOrDefault(r => r.Path == keep) ?? Logs.FirstOrDefault();
        OnPropertyChanged(nameof(CountLabel));
    }

    partial void OnFilterChanged(string value) => ApplyFilter();

    private void ApplyFilter()
    {
        var term = Filter?.Trim() ?? "";
        var matches = string.IsNullOrEmpty(term)
            ? _all
            : _all.Where(r => r.Name.Contains(term, StringComparison.OrdinalIgnoreCase)).ToList();
        Logs.Clear();
        foreach (var r in matches) Logs.Add(r);
    }

    partial void OnSelectedLogChanged(SessionLogRow? value)
    {
        OnPropertyChanged(nameof(HasSelection));
        LoadPreview(value);
    }

    private void LoadPreview(SessionLogRow? row)
    {
        if (row is null) { Preview = ""; return; }
        try
        {
            using var stream = new FileStream(row.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            var buffer = new byte[PreviewLimit];
            var read = stream.Read(buffer, 0, buffer.Length);
            var text = System.Text.Encoding.UTF8.GetString(buffer, 0, read);
            if (stream.Length > PreviewLimit)
                text += "\n\n… (truncated — open the file to see the full log)";
            Preview = text;
        }
        catch (Exception ex) { Preview = "Couldn't read this log: " + ex.Message; }
    }

    [RelayCommand]
    private void Open()
    {
        if (SelectedLog is { } row) _open(row.Path);
    }

    [RelayCommand]
    private void Reveal()
    {
        if (SelectedLog is { } row) _reveal(row.Path);
    }

    [RelayCommand]
    private void Delete()
    {
        if (SelectedLog is not { } row) return;
        try { File.Delete(row.Path); } catch { /* already gone / locked */ }
        Reload();
    }
}
