using System;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Services;

namespace RemoteStuff.ViewModels;

/// <summary>One row in the local (Finder) file browser.</summary>
public sealed class LocalEntryViewModel
{
    public required string Name { get; init; }
    public required string FullPath { get; init; }
    public bool IsDirectory { get; init; }
    public bool IsParent { get; init; }
    public long Size { get; init; }
    public DateTime Modified { get; init; }

    public string Glyph => IsParent ? "\u21A9" : IsDirectory ? "\U0001F4C1" : "\U0001F4C4";
    public string SizeText => IsDirectory ? "" : HumanSize(Size);
    public string ModifiedText => IsParent ? "" : Modified.ToString("yyyy-MM-dd HH:mm");

    /// <summary>A sort key for "kind": folders first, then by file extension.</summary>
    public string Kind => IsDirectory ? "" : Path.GetExtension(Name).ToLowerInvariant();

    private static string HumanSize(long bytes)
    {
        string[] units = { "B", "KB", "MB", "GB", "TB" };
        double v = bytes; var u = 0;
        while (v >= 1024 && u < units.Length - 1) { v /= 1024; u++; }
        return u == 0 ? $"{bytes} B" : $"{v:0.#} {units[u]}";
    }
}

/// <summary>A local file-browser ("Finder") tab.</summary>
public sealed partial class FinderTabViewModel : TabViewModel
{
    public override string Glyph => "\U0001F5C2";

    public ObservableCollection<LocalEntryViewModel> Entries { get; } = new();

    /// <summary>The full, unfiltered listing of the current directory (sort/filter source).</summary>
    private readonly System.Collections.Generic.List<LocalEntryViewModel> _all = new();

    public enum FinderSort { Name, Size, Modified, Kind }

    public System.Collections.Generic.IReadOnlyList<FinderSort> SortModes { get; } =
        Enum.GetValues(typeof(FinderSort)).Cast<FinderSort>().ToList();

    [ObservableProperty] private string _currentPath = "";
    [ObservableProperty] private bool _isBusy;
    [ObservableProperty] private string _statusText = "";
    [ObservableProperty] private LocalEntryViewModel? _selectedEntry;

    [ObservableProperty] private FinderSort _sortMode = FinderSort.Name;
    [ObservableProperty] private bool _sortAscending = true;
    [ObservableProperty] private string _filterText = "";
    [ObservableProperty] private bool _showHidden;
    [ObservableProperty] private string _pathInput = "";

    partial void OnSortModeChanged(FinderSort value) => ApplyView();
    partial void OnSortAscendingChanged(bool value) => ApplyView();
    partial void OnFilterTextChanged(string value) => ApplyView();
    partial void OnShowHiddenChanged(bool value) => LoadDirectory(CurrentPath);

    /// <summary>Raised to open a local text file in an editor tab: (name, content, saver).</summary>
    public event Action<string, string, Func<string, Task>>? EditRequested;

    private static readonly string[] TextExtensions =
    {
        ".txt", ".md", ".json", ".xml", ".yaml", ".yml", ".cs", ".js", ".ts", ".py",
        ".sh", ".conf", ".cfg", ".ini", ".log", ".css", ".html", ".htm", ".sql",
        ".c", ".h", ".cpp", ".hpp", ".java", ".go", ".rs", ".rb", ".php", ".toml",
        ".gitignore", ".env", ".plist", ".swift", ".kt", ".gradle", ".properties"
    };

    public FinderTabViewModel(string? startPath = null)
    {
        Title = "Finder";
        var start = string.IsNullOrWhiteSpace(startPath)
            ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
            : startPath;
        LoadDirectory(Directory.Exists(start) ? start : Environment.CurrentDirectory);
    }

    public override RemoteStuff.Services.TabSnapshot? CreateSnapshot() => new RemoteStuff.Services.TabSnapshot
    {
        Kind = "finder",
        Title = Title,
        Path = CurrentPath
    };

    /// <summary>Reload the current directory (e.g. after a drag-and-drop download).</summary>
    public void ReloadCurrentDirectory() => LoadDirectory(CurrentPath);

    private void LoadDirectory(string path)
    {
        IsBusy = true;
        try
        {
            var dir = new DirectoryInfo(path);
            var full = dir.FullName;

            var dirs = dir.EnumerateDirectories()
                .Where(d => ShowHidden || (d.Attributes & FileAttributes.Hidden) == 0);
            var files = dir.EnumerateFiles()
                .Where(f => ShowHidden || (f.Attributes & FileAttributes.Hidden) == 0);

            _all.Clear();
            var parent = dir.Parent;
            if (parent != null)
                _all.Add(new LocalEntryViewModel
                {
                    Name = "..", FullPath = parent.FullName, IsDirectory = true, IsParent = true
                });

            foreach (var d in dirs)
                _all.Add(new LocalEntryViewModel
                {
                    Name = d.Name, FullPath = d.FullName, IsDirectory = true, Modified = d.LastWriteTime
                });
            foreach (var f in files)
                _all.Add(new LocalEntryViewModel
                {
                    Name = f.Name, FullPath = f.FullName, IsDirectory = false,
                    Size = f.Length, Modified = f.LastWriteTime
                });

            CurrentPath = full;
            PathInput = full;
            Title = "Finder · " + dir.Name;
            ApplyView();
        }
        catch (Exception ex)
        {
            StatusText = "Error: " + ex.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }

    /// <summary>Re-apply the current filter + sort to <see cref="_all"/> into <see cref="Entries"/>.</summary>
    private void ApplyView()
    {
        var filter = FilterText?.Trim() ?? "";
        System.Collections.Generic.IEnumerable<LocalEntryViewModel> items = _all
            .Where(e => e.IsParent || filter.Length == 0
                        || e.Name.Contains(filter, StringComparison.OrdinalIgnoreCase));

        // Keep ".." pinned to the top, folders before files, then the chosen key.
        Comparison<LocalEntryViewModel> cmp = (a, b) =>
        {
            var key = SortMode switch
            {
                FinderSort.Size => a.Size.CompareTo(b.Size),
                FinderSort.Modified => a.Modified.CompareTo(b.Modified),
                FinderSort.Kind => string.Compare(a.Kind, b.Kind, StringComparison.OrdinalIgnoreCase),
                _ => string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase)
            };
            if (SortMode == FinderSort.Name || key == 0)
                key = string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase);
            return SortAscending ? key : -key;
        };

        var sorted = items.Where(e => !e.IsParent).ToList();
        sorted.Sort((a, b) =>
        {
            if (a.IsDirectory != b.IsDirectory) return a.IsDirectory ? -1 : 1;
            return cmp(a, b);
        });

        Entries.Clear();
        var parent = _all.FirstOrDefault(e => e.IsParent);
        if (parent != null) Entries.Add(parent);
        foreach (var e in sorted) Entries.Add(e);

        StatusText = $"{Entries.Count(e => !e.IsParent)} items"
            + (filter.Length > 0 ? $" (filtered)" : "");
    }

    [RelayCommand]
    private void Open(LocalEntryViewModel? entry)
    {
        entry ??= SelectedEntry;
        if (entry is null) return;
        if (entry.IsDirectory)
        {
            LoadDirectory(entry.FullPath);
            return;
        }

        var ext = Path.GetExtension(entry.Name).ToLowerInvariant();
        if (TextExtensions.Contains(ext) || string.IsNullOrEmpty(ext))
            EditLocal(entry);
        else
            OpenExternally(entry);
    }

    private void EditLocal(LocalEntryViewModel entry)
    {
        try
        {
            var text = File.ReadAllText(entry.FullPath);
            var path = entry.FullPath;
            EditRequested?.Invoke(entry.Name, text, async content =>
            {
                await Task.Run(() => File.WriteAllText(path, content));
            });
            StatusText = "Opened " + entry.Name + " in editor";
        }
        catch (Exception ex) { StatusText = "Open failed: " + ex.Message; }
    }

    [RelayCommand]
    private void OpenExternally(LocalEntryViewModel? entry)
    {
        entry ??= SelectedEntry;
        if (entry is null) return;
        try
        {
            Process.Start(new ProcessStartInfo(entry.FullPath) { UseShellExecute = true });
        }
        catch (Exception ex) { StatusText = "Open failed: " + ex.Message; }
    }

    [RelayCommand]
    private void Refresh() => LoadDirectory(CurrentPath);

    [RelayCommand]
    private void GoToPath()
    {
        var target = PathInput?.Trim();
        if (string.IsNullOrEmpty(target)) return;
        if (target.StartsWith("~"))
            target = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
                     + target[1..];
        if (Directory.Exists(target))
            LoadDirectory(target);
        else if (File.Exists(target))
        {
            var parent = Path.GetDirectoryName(target);
            if (parent != null) LoadDirectory(parent);
        }
        else
            StatusText = "No such folder: " + target;
    }

    [RelayCommand]
    private void ToggleSortDirection() => SortAscending = !SortAscending;

    [RelayCommand]
    private void GoUp()
    {
        var parent = Directory.GetParent(CurrentPath);
        if (parent != null) LoadDirectory(parent.FullName);
    }

    [RelayCommand]
    private void GoHome() =>
        LoadDirectory(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));

    [RelayCommand]
    private void RevealInFinder()
    {
        var target = SelectedEntry?.FullPath ?? CurrentPath;
        try
        {
            if (OperatingSystem.IsMacOS())
                Process.Start("open", SelectedEntry is null ? new[] { target } : new[] { "-R", target });
            else if (OperatingSystem.IsWindows())
                Process.Start("explorer", $"/select,\"{target}\"");
            else
                Process.Start(new ProcessStartInfo(Path.GetDirectoryName(target) ?? target) { UseShellExecute = true });
        }
        catch (Exception ex) { StatusText = "Reveal failed: " + ex.Message; }
    }

    [RelayCommand]
    private async Task NewFolder()
    {
        var name = "New Folder";
        var target = Path.Combine(CurrentPath, name);
        var n = 2;
        while (Directory.Exists(target))
            target = Path.Combine(CurrentPath, $"{name} {n++}");
        try
        {
            await Task.Run(() => Directory.CreateDirectory(target));
            LoadDirectory(CurrentPath);
        }
        catch (Exception ex) { StatusText = "Create failed: " + ex.Message; }
    }

    [RelayCommand]
    private async Task Delete(LocalEntryViewModel? entry)
    {
        entry ??= SelectedEntry;
        if (entry is null || entry.IsParent) return;
        try
        {
            await Task.Run(() =>
            {
                if (entry.IsDirectory) Directory.Delete(entry.FullPath, recursive: true);
                else File.Delete(entry.FullPath);
            });
            LoadDirectory(CurrentPath);
        }
        catch (Exception ex) { StatusText = "Delete failed: " + ex.Message; }
    }

    /// <summary>Copy the selected item's full path to the clipboard via the dialog top-level.</summary>
    [RelayCommand]
    private async Task CopyPath()
    {
        var path = SelectedEntry?.FullPath ?? CurrentPath;
        if (DialogService.Top?.Clipboard is { } cb)
            await cb.SetTextAsync(path);
        StatusText = "Copied path";
    }
}
