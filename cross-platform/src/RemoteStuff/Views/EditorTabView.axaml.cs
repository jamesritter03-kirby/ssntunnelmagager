using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Markup.Xaml;
using AvaloniaEdit;
using AvaloniaEdit.Search;
using AvaloniaEdit.TextMate;
using TextMateSharp.Grammars;
using RemoteStuff.ViewModels;

namespace RemoteStuff.Views;

public partial class EditorTabView : UserControl
{
    private TextEditor? _editor;
    private EditorTabViewModel? _vm;
    private bool _syncing;
    private TextMate.Installation? _textMate;
    private RegistryOptions? _registryOptions;

    public EditorTabView()
    {
        InitializeComponent();
        _editor = this.FindControl<TextEditor>("Editor");
        if (_editor != null)
        {
            _editor.TextChanged += OnEditorTextChanged;
            _registryOptions = new RegistryOptions(CurrentThemeName());
            _textMate = _editor.InstallTextMate(_registryOptions);
            SearchPanel.Install(_editor);
            _editor.AddHandler(KeyDownEvent, OnEditorKeyDown, Avalonia.Interactivity.RoutingStrategies.Tunnel);
        }
        if (Avalonia.Application.Current is { } app)
            app.ActualThemeVariantChanged += OnAppThemeVariantChanged;
        DataContextChanged += OnDataContextChanged;
    }

    private void InitializeComponent() => AvaloniaXamlLoader.Load(this);

    /// <summary>Pick the TextMate colour theme that matches the current app theme variant.</summary>
    private static ThemeName CurrentThemeName() =>
        Avalonia.Application.Current?.ActualThemeVariant == Avalonia.Styling.ThemeVariant.Light
            ? ThemeName.LightPlus
            : ThemeName.DarkPlus;

    private void OnAppThemeVariantChanged(object? sender, System.EventArgs e)
    {
        if (_textMate is null || _registryOptions is null) return;
        _registryOptions = new RegistryOptions(CurrentThemeName());
        _textMate.SetTheme(_registryOptions.GetDefaultTheme());
        if (_vm != null) ApplyLanguage(_vm.Language);
    }

    private void OnDataContextChanged(object? sender, System.EventArgs e)
    {
        if (_vm != null)
        {
            _vm.PropertyChanged -= OnVmPropertyChanged;
            _vm.ActionRequested -= OnEditorAction;
            _vm.GoToLineRequested -= OnGoToLineRequested;
        }
        _vm = DataContext as EditorTabViewModel;
        if (_vm != null && _editor != null)
        {
            _syncing = true;
            _editor.Text = _vm.Text;
            _syncing = false;
            ApplyLanguage(_vm.Language);
            ApplyEditorOptions();
            _vm.PropertyChanged += OnVmPropertyChanged;
            _vm.ActionRequested += OnEditorAction;
            _vm.GoToLineRequested += OnGoToLineRequested;
        }
    }

    private void OnVmPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(EditorTabViewModel.Text) && _editor != null && !_syncing
            && _editor.Text != _vm!.Text)
        {
            _syncing = true;
            _editor.Text = _vm.Text;
            _syncing = false;
        }
        else if (e.PropertyName == nameof(EditorTabViewModel.Language) && _vm != null)
        {
            ApplyLanguage(_vm.Language);
        }
        else if (e.PropertyName is nameof(EditorTabViewModel.HighlightCurrentLine)
                 or nameof(EditorTabViewModel.ShowWhitespace)
                 or nameof(EditorTabViewModel.ShowColumnRuler))
        {
            ApplyEditorOptions();
        }
    }

    /// <summary>Push the VM's view-option toggles into the editor's <see cref="AvaloniaEdit.TextEditorOptions"/>.</summary>
    private void ApplyEditorOptions()
    {
        if (_editor is null || _vm is null) return;
        var opts = _editor.Options;
        opts.HighlightCurrentLine = _vm.HighlightCurrentLine;
        opts.ShowSpaces = _vm.ShowWhitespace;
        opts.ShowTabs = _vm.ShowWhitespace;
        opts.ShowColumnRulers = _vm.ShowColumnRuler;
        opts.ColumnRulerPositions = _vm.ShowColumnRuler ? new[] { 80 } : System.Array.Empty<int>();
    }

    private void OnEditorTextChanged(object? sender, System.EventArgs e)
    {
        if (_syncing || _vm is null || _editor is null) return;
        _syncing = true;
        _vm.Text = _editor.Text;
        _syncing = false;
    }

    private void OnFind(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
    {
        if (_editor?.SearchPanel is { } panel)
            panel.Open();
        else if (_editor != null)
            SearchPanel.Install(_editor).Open();
    }

    /// <summary>Prompt for a line number and move the caret there.</summary>
    private async void OnGoToLineRequested()
    {
        if (_editor?.Document is null) return;
        if (TopLevel.GetTopLevel(this) is not Window owner) return;
        var caret = _editor.TextArea.Caret;
        var answer = await TextPromptWindow.ShowAsync(owner,
            $"Go to line (1–{_editor.Document.LineCount})", caret.Line.ToString());
        if (string.IsNullOrWhiteSpace(answer)) return;
        if (!int.TryParse(answer.Trim(), out var line)) return;
        line = System.Math.Clamp(line, 1, _editor.Document.LineCount);
        var docLine = _editor.Document.GetLineByNumber(line);
        caret.Line = line;
        caret.Column = 1;
        _editor.ScrollToLine(line);
        _editor.Select(docLine.Offset, 0);
        _editor.TextArea.Focus();
    }

    // --- Smart-editing commands (mirror the Mac app's Scintilla actions) ---

    private void OnEditorKeyDown(object? sender, KeyEventArgs e)
    {
        var ctrl = e.KeyModifiers.HasFlag(KeyModifiers.Control) || e.KeyModifiers.HasFlag(KeyModifiers.Meta);
        var alt = e.KeyModifiers.HasFlag(KeyModifiers.Alt);
        var shift = e.KeyModifiers.HasFlag(KeyModifiers.Shift);

        if (alt && !ctrl && e.Key == Key.Up) { OnEditorAction(EditorAction.MoveLineUp); e.Handled = true; }
        else if (alt && !ctrl && e.Key == Key.Down) { OnEditorAction(EditorAction.MoveLineDown); e.Handled = true; }
        else if (ctrl && shift && e.Key == Key.D) { OnEditorAction(EditorAction.DuplicateLine); e.Handled = true; }
        else if (ctrl && shift && e.Key == Key.K) { OnEditorAction(EditorAction.DeleteLine); e.Handled = true; }
        else if (ctrl && !shift && e.Key == Key.G) { OnGoToLineRequested(); e.Handled = true; }
        else if (ctrl && !shift && (e.Key == Key.OemQuestion || e.Key == Key.Divide))
        {
            OnEditorAction(EditorAction.ToggleComment);
            e.Handled = true;
        }
    }

    private void OnEditorAction(EditorAction action)
    {
        if (_editor?.Document is null) return;
        switch (action)
        {
            case EditorAction.MoveLineUp: MoveLine(-1); break;
            case EditorAction.MoveLineDown: MoveLine(1); break;
            case EditorAction.DuplicateLine: DuplicateLine(); break;
            case EditorAction.DeleteLine: DeleteLine(); break;
            case EditorAction.ToggleComment: ToggleComment(); break;
        }
    }

    private void MoveLine(int direction)
    {
        var doc = _editor!.Document;
        var caret = _editor.TextArea.Caret;
        int ln = caret.Line;
        int other = ln + direction;
        if (other < 1 || other > doc.LineCount) return;

        var cur = doc.GetLineByNumber(ln);
        var swap = doc.GetLineByNumber(other);
        var curText = doc.GetText(cur.Offset, cur.Length);
        var swapText = doc.GetText(swap.Offset, swap.Length);
        int col = caret.Column;

        doc.BeginUpdate();
        // Replace the later line first so the earlier line's offset stays valid.
        if (direction > 0)
        {
            doc.Replace(swap.Offset, swap.Length, curText);
            doc.Replace(cur.Offset, cur.Length, swapText);
        }
        else
        {
            doc.Replace(cur.Offset, cur.Length, swapText);
            doc.Replace(swap.Offset, swap.Length, curText);
        }
        doc.EndUpdate();

        var moved = doc.GetLineByNumber(other);
        caret.Line = other;
        caret.Column = System.Math.Min(col, moved.Length + 1);
    }

    private void DuplicateLine()
    {
        var doc = _editor!.Document;
        var caret = _editor.TextArea.Caret;
        var line = doc.GetLineByNumber(caret.Line);
        var text = doc.GetText(line.Offset, line.Length);
        doc.Insert(line.Offset, text + "\n");
        caret.Line += 1;
    }

    private void DeleteLine()
    {
        var doc = _editor!.Document;
        var caret = _editor.TextArea.Caret;
        var line = doc.GetLineByNumber(caret.Line);
        doc.Remove(line.Offset, line.TotalLength);
    }

    private void ToggleComment()
    {
        var doc = _editor!.Document;
        var (prefix, blockStart, blockEnd) = CommentTokens(_vm?.Language ?? "Plain Text");
        var sel = _editor.TextArea.Selection;

        int startLine, endLine;
        if (!sel.IsEmpty)
        {
            var seg = sel.SurroundingSegment;
            startLine = doc.GetLineByOffset(seg.Offset).LineNumber;
            int endOffset = seg.Offset + seg.Length;
            endLine = doc.GetLineByOffset(System.Math.Max(seg.Offset, endOffset - 1)).LineNumber;
        }
        else
        {
            startLine = endLine = _editor.TextArea.Caret.Line;
        }

        if (prefix != null)
        {
            bool allCommented = true;
            for (int i = startLine; i <= endLine; i++)
            {
                var l = doc.GetLineByNumber(i);
                var t = doc.GetText(l.Offset, l.Length);
                if (t.Trim().Length == 0) continue;
                if (!t.TrimStart().StartsWith(prefix, System.StringComparison.Ordinal)) { allCommented = false; break; }
            }

            doc.BeginUpdate();
            for (int i = startLine; i <= endLine; i++)
            {
                var l = doc.GetLineByNumber(i);
                var t = doc.GetText(l.Offset, l.Length);
                if (t.Trim().Length == 0) continue;
                int leading = t.Length - t.TrimStart().Length;
                if (allCommented)
                {
                    int removeLen = prefix.Length;
                    if (leading + prefix.Length < t.Length && t[leading + prefix.Length] == ' ') removeLen++;
                    doc.Remove(l.Offset + leading, removeLen);
                }
                else
                {
                    doc.Insert(l.Offset + leading, prefix + " ");
                }
            }
            doc.EndUpdate();
        }
        else if (blockStart != null && blockEnd != null)
        {
            var startSeg = doc.GetLineByNumber(startLine);
            var endSeg = doc.GetLineByNumber(endLine);
            int from = startSeg.Offset;
            int to = endSeg.EndOffset;
            var text = doc.GetText(from, to - from);
            var trimmed = text.Trim();
            doc.BeginUpdate();
            if (trimmed.StartsWith(blockStart, System.StringComparison.Ordinal)
                && trimmed.EndsWith(blockEnd, System.StringComparison.Ordinal))
            {
                var inner = trimmed.Substring(blockStart.Length,
                    trimmed.Length - blockStart.Length - blockEnd.Length).Trim();
                doc.Replace(from, to - from, inner);
            }
            else
            {
                doc.Replace(from, to - from, blockStart + " " + text + " " + blockEnd);
            }
            doc.EndUpdate();
        }
    }

    /// <summary>Single-line prefix or block comment tokens for a language name.</summary>
    private static (string? prefix, string? blockStart, string? blockEnd) CommentTokens(string language) => language switch
    {
        "C#" or "JavaScript" or "TypeScript" or "C" or "C++" or "Go" or "Rust" or "Java" or "PHP" or "Swift"
            => ("//", null, null),
        "Python" or "Shell" or "YAML" or "Ruby" or "TOML" => ("#", null, null),
        "INI" => (";", null, null),
        "SQL" => ("--", null, null),
        "CSS" => (null, "/*", "*/"),
        "XML" or "HTML" => (null, "<!--", "-->"),
        _ => (null, null, null)
    };

    /// <summary>Map a friendly language name to a TextMate grammar and apply it.</summary>
    private void ApplyLanguage(string language)
    {
        if (_textMate is null || _registryOptions is null) return;
        var ext = ExtensionFor(language);
        if (ext is null)
        {
            _textMate.SetGrammar(null);
            return;
        }
        try
        {
            var lang = _registryOptions.GetLanguageByExtension(ext);
            if (lang is null)
            {
                _textMate.SetGrammar(null);
                return;
            }
            _textMate.SetGrammar(_registryOptions.GetScopeByLanguageId(lang.Id));
        }
        catch
        {
            _textMate.SetGrammar(null);
        }
    }

    private static string? ExtensionFor(string language) => language switch
    {
        "C#" => ".cs",
        "JavaScript" => ".js",
        "TypeScript" => ".ts",
        "Python" => ".py",
        "JSON" => ".json",
        "XML" => ".xml",
        "HTML" => ".html",
        "CSS" => ".css",
        "Shell" => ".sh",
        "YAML" => ".yaml",
        "Markdown" => ".md",
        "SQL" => ".sql",
        "C" => ".c",
        "C++" => ".cpp",
        "Go" => ".go",
        "Rust" => ".rs",
        "Java" => ".java",
        "PHP" => ".php",
        "Ruby" => ".rb",
        "Swift" => ".swift",
        "TOML" => ".toml",
        "INI" => ".ini",
        _ => null
    };
}
