using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Services;

namespace RemoteStuff.ViewModels;

/// <summary>A lightweight text-editor tab (AvaloniaEdit) for local or remote files.</summary>
public sealed partial class EditorTabViewModel : TabViewModel
{
    private readonly Func<string, Task>? _remoteSaver;

    public override string Glyph => "✎";

    [ObservableProperty] private string _text = "";
    [ObservableProperty] private string? _filePath;
    [ObservableProperty] private bool _isDirty;
    [ObservableProperty] private string _statusText = "";

    /// <summary>The selected syntax language (drives TextMate highlighting in the view).</summary>
    [ObservableProperty] private string _language = "Plain Text";

    /// <summary>Newline convention used when saving.</summary>
    [ObservableProperty] private string _lineEnding = "LF";

    /// <summary>Text encoding used when reading/writing the file.</summary>
    [ObservableProperty] private string _encoding = "UTF-8";

    /// <summary>When true, saving first copies the previous file to a <c>.bak</c> sibling.</summary>
    [ObservableProperty] private bool _keepBackup;

    // --- Editor view options (mirror the Mac app's Scintilla toolbar) ---

    /// <summary>Soft-wrap long lines instead of scrolling horizontally.</summary>
    [ObservableProperty] private bool _wordWrap;

    /// <summary>Show the line-number gutter.</summary>
    [ObservableProperty] private bool _showLineNumbers = true;

    /// <summary>Highlight the line the caret is on.</summary>
    [ObservableProperty] private bool _highlightCurrentLine = true;

    /// <summary>Render spaces and tabs as visible glyphs.</summary>
    [ObservableProperty] private bool _showWhitespace;

    /// <summary>Draw a vertical ruler at column 80.</summary>
    [ObservableProperty] private bool _showColumnRuler;

    /// <summary>Editor font size (points).</summary>
    [ObservableProperty] private double _fontSize = 13;

    /// <summary>Raised for smart-editing commands the view applies to the editor.</summary>
    public event Action<EditorAction>? ActionRequested;

    /// <summary>Raised when the user asks to jump to a line (the view prompts and moves the caret).</summary>
    public event Action? GoToLineRequested;

    /// <summary>Other open editors this buffer can be compared against. Kept current
    /// by the main view-model; drives the toolbar "Compare ▾" flyout.</summary>
    public System.Collections.ObjectModel.ObservableCollection<CompareTarget> CompareTargets { get; } = new();

    public bool HasCompareTargets => CompareTargets.Count > 0;

    /// <summary>Called by the main view-model after refreshing <see cref="CompareTargets"/>.</summary>
    public void NotifyCompareTargetsChanged() => OnPropertyChanged(nameof(HasCompareTargets));

    /// <summary>Languages the user can pick from (names map to TextMate grammars in the view).</summary>
    public IReadOnlyList<string> Languages { get; } = new[]
    {
        "Plain Text", "C#", "JavaScript", "TypeScript", "Python", "JSON", "XML", "HTML",
        "CSS", "Shell", "YAML", "Markdown", "SQL", "C", "C++", "Go", "Rust", "Java", "PHP", "Ruby",
        "Swift", "TOML", "INI"
    };

    /// <summary>Newline options for the picker.</summary>
    public IReadOnlyList<string> LineEndings { get; } = new[] { "LF", "CRLF" };

    /// <summary>Text-encoding options for the picker.</summary>
    public IReadOnlyList<string> Encodings { get; } = new[]
    {
        "UTF-8", "UTF-8 with BOM", "UTF-16 LE", "UTF-16 BE"
    };

    private readonly string _baseTitle;

    /// <summary>Stable id used to key this buffer's crash-safe backup file.</summary>
    public string BackupId { get; }

    // --- External-change detection banner ---

    /// <summary>The file changed on disk outside the editor.</summary>
    [ObservableProperty] private bool _diskChanged;

    /// <summary>The file was moved or deleted on disk.</summary>
    [ObservableProperty] private bool _diskDeleted;

    private FileSystemWatcher? _watcher;
    private DateTime _diskBaseline;
    private System.Threading.Timer? _backupTimer;
    private bool _restoring;

    public EditorTabViewModel(string title, string initialText = "", string? filePath = null,
        Func<string, Task>? remoteSaver = null, string? backupId = null)
    {
        _baseTitle = title;
        Title = title;
        _text = initialText;
        _filePath = filePath;
        _remoteSaver = remoteSaver;
        _lineEnding = initialText.Contains("\r\n") ? "CRLF" : "LF";
        _language = LanguageForPath(filePath);
        BackupId = backupId ?? Guid.NewGuid().ToString("N");
        if (filePath != null) StartWatching(filePath);
    }

    /// <summary>Rebuild an editor tab from a recovered crash backup.</summary>
    public static EditorTabViewModel FromBackup(EditorBackupStore.Backup b)
    {
        var title = string.IsNullOrWhiteSpace(b.Title) ? "Recovered" : b.Title;
        var vm = new EditorTabViewModel(title, b.Text, b.FilePath, backupId: b.Id)
        {
            Language = string.IsNullOrWhiteSpace(b.Language) ? "Plain Text" : b.Language,
            LineEnding = string.IsNullOrWhiteSpace(b.LineEnding) ? "LF" : b.LineEnding,
            Encoding = string.IsNullOrWhiteSpace(b.Encoding) ? "UTF-8" : b.Encoding,
        };
        vm.IsDirty = true;
        vm.Title = title + " •";
        vm.StatusText = "Recovered unsaved changes";
        return vm;
    }

    partial void OnTextChanged(string value)
    {
        IsDirty = true;
        Title = _baseTitle + " •";
        if (!_restoring) ScheduleBackup();
    }

    partial void OnIsDirtyChanged(bool value)
    {
        // A clean buffer has nothing worth recovering.
        if (!value) EditorBackupStore.Delete(BackupId);
    }

    // --- Crash-safe backup (debounced) ---

    /// <summary>Queue a debounced backup write ~0.7s after the last edit.</summary>
    private void ScheduleBackup()
    {
        _backupTimer ??= new System.Threading.Timer(_ => WriteBackup());
        _backupTimer.Change(700, System.Threading.Timeout.Infinite);
    }

    private void WriteBackup()
    {
        if (!IsDirty) return;
        EditorBackupStore.Save(new EditorBackupStore.Backup
        {
            Id = BackupId,
            Title = _baseTitle,
            FilePath = FilePath,
            Text = Text,
            Language = Language,
            LineEnding = LineEnding,
            Encoding = Encoding,
        });
    }

    // --- External file-change detection ---

    partial void OnFilePathChanged(string? value)
    {
        if (!string.IsNullOrEmpty(value)) StartWatching(value);
    }

    private void StartWatching(string path)
    {
        try
        {
            _watcher?.Dispose();
            var dir = Path.GetDirectoryName(path);
            var name = Path.GetFileName(path);
            if (string.IsNullOrEmpty(dir) || string.IsNullOrEmpty(name)) return;
            _diskBaseline = File.Exists(path) ? File.GetLastWriteTimeUtc(path) : DateTime.MinValue;
            _watcher = new FileSystemWatcher(dir, name)
            {
                NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size
                             | NotifyFilters.FileName | NotifyFilters.CreationTime,
                EnableRaisingEvents = true,
            };
            _watcher.Changed += OnFileEvent;
            _watcher.Created += OnFileEvent;
            _watcher.Renamed += OnFileRenamed;
            _watcher.Deleted += OnFileDeleted;
        }
        catch { /* watching is best-effort */ }
    }

    private void OnFileEvent(object? sender, FileSystemEventArgs e)
    {
        if (FilePath is null) return;
        try
        {
            if (!File.Exists(FilePath)) return;
            var write = File.GetLastWriteTimeUtc(FilePath);
            if (write == _diskBaseline) return; // our own write
            Avalonia.Threading.Dispatcher.UIThread.Post(() =>
            {
                DiskDeleted = false;
                DiskChanged = true;
            });
        }
        catch { /* ignore */ }
    }

    private void OnFileRenamed(object? sender, RenamedEventArgs e) => OnFileDeleted(sender, e);

    private void OnFileDeleted(object? sender, FileSystemEventArgs e)
    {
        if (FilePath is null) return;
        Avalonia.Threading.Dispatcher.UIThread.Post(() =>
        {
            if (FilePath != null && File.Exists(FilePath)) return;
            DiskChanged = false;
            DiskDeleted = true;
        });
    }

    /// <summary>Discard local edits and reload the current file from disk.</summary>
    [RelayCommand]
    private async Task ReloadFromDisk()
    {
        DiskChanged = false;
        DiskDeleted = false;
        if (string.IsNullOrEmpty(FilePath) || !File.Exists(FilePath)) return;
        try
        {
            var bytes = await File.ReadAllBytesAsync(FilePath);
            var (content, enc) = ReadWithEncoding(bytes);
            _restoring = true;
            Encoding = enc;
            LineEnding = content.Contains("\r\n") ? "CRLF" : "LF";
            Text = content;
            _restoring = false;
            _diskBaseline = File.GetLastWriteTimeUtc(FilePath);
            IsDirty = false;
            Title = _baseTitle;
            StatusText = "Reloaded from disk";
        }
        catch (Exception ex) { StatusText = "Reload failed: " + ex.Message; }
    }

    /// <summary>Dismiss the change banner and keep the in-editor version.</summary>
    [RelayCommand]
    private void KeepMine()
    {
        DiskChanged = false;
        DiskDeleted = false;
        // Adopt the current on-disk timestamp so we don't re-notify for this change.
        try { if (FilePath != null && File.Exists(FilePath)) _diskBaseline = File.GetLastWriteTimeUtc(FilePath); }
        catch { /* ignore */ }
    }

    /// <summary>Keep the (now-deleted) file's contents in the editor as unsaved work.</summary>
    [RelayCommand]
    private void KeepInEditor()
    {
        DiskDeleted = false;
        IsDirty = true;
        Title = _baseTitle + " •";
    }

    public override void Dispose()
    {
        _backupTimer?.Dispose();
        _watcher?.Dispose();
        // Normal close: drop the recovery backup (a crash would leave it behind).
        EditorBackupStore.Delete(BackupId);
        base.Dispose();
    }

    /// <summary>Apply the chosen line-ending convention to the text.</summary>
    private string NormalizedText()
    {
        var lf = Text.Replace("\r\n", "\n").Replace("\r", "\n");
        return LineEnding == "CRLF" ? lf.Replace("\n", "\r\n") : lf;
    }

    /// <summary>Write a <c>.bak</c> copy of an existing file before overwriting it.</summary>
    private void MaybeBackup(string path)
    {
        if (!KeepBackup || !File.Exists(path)) return;
        try { File.Copy(path, path + ".bak", overwrite: true); } catch { /* best-effort */ }
    }

    /// <summary>Guess a language name from a file extension.</summary>
    public static string LanguageForPath(string? path)
    {
        var ext = Path.GetExtension(path ?? "").ToLowerInvariant();
        return ext switch
        {
            ".cs" => "C#",
            ".js" or ".mjs" or ".cjs" => "JavaScript",
            ".ts" or ".tsx" => "TypeScript",
            ".py" => "Python",
            ".json" => "JSON",
            ".xml" or ".xaml" or ".axaml" or ".csproj" or ".plist" => "XML",
            ".html" or ".htm" => "HTML",
            ".css" => "CSS",
            ".sh" or ".bash" or ".zsh" => "Shell",
            ".yml" or ".yaml" => "YAML",
            ".md" or ".markdown" => "Markdown",
            ".sql" => "SQL",
            ".c" or ".h" => "C",
            ".cpp" or ".cc" or ".hpp" or ".cxx" => "C++",
            ".go" => "Go",
            ".rs" => "Rust",
            ".java" => "Java",
            ".php" => "PHP",
            ".rb" => "Ruby",
            ".swift" => "Swift",
            ".toml" => "TOML",
            ".ini" or ".cfg" or ".conf" or ".properties" => "INI",
            _ => "Plain Text"
        };
    }

    /// <summary>Resolve the chosen encoding name to a concrete <see cref="System.Text.Encoding"/>.</summary>
    private Encoding ResolveEncoding() => Encoding switch
    {
        "UTF-8 with BOM" => new UTF8Encoding(true),
        "UTF-16 LE" => new UnicodeEncoding(false, true),
        "UTF-16 BE" => new UnicodeEncoding(true, true),
        _ => new UTF8Encoding(false)
    };

    /// <summary>Read a text file, detecting its encoding from a byte-order mark.</summary>
    private static (string text, string encoding) ReadWithEncoding(byte[] bytes)
    {
        if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
            return (new UTF8Encoding(false).GetString(bytes, 3, bytes.Length - 3), "UTF-8 with BOM");
        if (bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE)
            return (System.Text.Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2), "UTF-16 LE");
        if (bytes.Length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF)
            return (System.Text.Encoding.BigEndianUnicode.GetString(bytes, 2, bytes.Length - 2), "UTF-16 BE");
        return (new UTF8Encoding(false).GetString(bytes), "UTF-8");
    }

    [RelayCommand]
    private async Task Save()
    {
        try
        {
            if (_remoteSaver != null)
            {
                await _remoteSaver(NormalizedText());
                StatusText = "Saved to remote host";
            }
            else if (!string.IsNullOrEmpty(FilePath))
            {
                MaybeBackup(FilePath);
                await File.WriteAllTextAsync(FilePath, NormalizedText(), ResolveEncoding());
                try { _diskBaseline = File.GetLastWriteTimeUtc(FilePath); } catch { }
                StatusText = "Saved " + Path.GetFileName(FilePath);
            }
            else
            {
                await SaveAs();
                return;
            }
            IsDirty = false;
            Title = _baseTitle;
        }
        catch (Exception ex)
        {
            StatusText = "Save failed: " + ex.Message;
        }
    }

    [RelayCommand]
    private async Task SaveAs()
    {
        var path = await DialogService.SaveFileAsync(
            string.IsNullOrEmpty(FilePath) ? "untitled.txt" : Path.GetFileName(FilePath), "Save as");
        if (string.IsNullOrEmpty(path)) return;
        try
        {
            MaybeBackup(path);
            await File.WriteAllTextAsync(path, NormalizedText(), ResolveEncoding());
            FilePath = path;
            try { _diskBaseline = File.GetLastWriteTimeUtc(path); } catch { }
            Language = LanguageForPath(path);
            IsDirty = false;
            Title = _baseTitle;
            StatusText = "Saved " + Path.GetFileName(path);
        }
        catch (Exception ex)
        {
            StatusText = "Save failed: " + ex.Message;
        }
    }

    [RelayCommand]
    private async Task Open()
    {
        var path = await DialogService.OpenFileAsync("Open file");
        if (string.IsNullOrEmpty(path)) return;
        try
        {
            var bytes = await File.ReadAllBytesAsync(path);
            var (content, enc) = ReadWithEncoding(bytes);
            Encoding = enc;
            LineEnding = content.Contains("\r\n") ? "CRLF" : "LF";
            Text = content;
            FilePath = path;
            Language = LanguageForPath(path);
            IsDirty = false;
            StatusText = "Opened " + Path.GetFileName(path);
        }
        catch (Exception ex)
        {
            StatusText = "Open failed: " + ex.Message;
        }
    }

    [RelayCommand]
    private async Task New()
    {
        if (IsDirty && !await DialogService.ConfirmAsync(
                "New document", "Discard unsaved changes and start a new document?"))
            return;
        Text = "";
        FilePath = null;
        Language = "Plain Text";
        LineEnding = "LF";
        IsDirty = false;
        StatusText = "New document";
        Title = _baseTitle;
    }

    [RelayCommand] private void IncreaseFont() => FontSize = Math.Min(40, FontSize + 1);
    [RelayCommand] private void DecreaseFont() => FontSize = Math.Max(8, FontSize - 1);

    [RelayCommand] private void GoToLine() => GoToLineRequested?.Invoke();

    [RelayCommand] private void MoveLineUp() => ActionRequested?.Invoke(EditorAction.MoveLineUp);
    [RelayCommand] private void MoveLineDown() => ActionRequested?.Invoke(EditorAction.MoveLineDown);
    [RelayCommand] private void DuplicateLine() => ActionRequested?.Invoke(EditorAction.DuplicateLine);
    [RelayCommand] private void DeleteLine() => ActionRequested?.Invoke(EditorAction.DeleteLine);
    [RelayCommand] private void ToggleComment() => ActionRequested?.Invoke(EditorAction.ToggleComment);
}

/// <summary>Smart-editing actions the editor view performs on the document.</summary>
public enum EditorAction
{
    MoveLineUp,
    MoveLineDown,
    DuplicateLine,
    DeleteLine,
    ToggleComment
}

/// <summary>One entry in an editor's "Compare ▾" flyout: another open editor and
/// the command that opens a side-by-side diff against it.</summary>
public sealed class CompareTarget
{
    public string Title { get; }
    public IRelayCommand CompareCommand { get; }

    public CompareTarget(string title, Action run)
    {
        Title = title;
        CompareCommand = new RelayCommand(run);
    }
}

