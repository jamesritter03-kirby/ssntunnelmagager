using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text.RegularExpressions;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace RemoteStuff.ViewModels;

/// <summary>klogg-style log tools for the editor: a filter (grep) pane, a search
/// results pane, marks, highlighters and follow (tail -f) mode.</summary>
public sealed partial class EditorTabViewModel
{
    // --- Panel state ---

    /// <summary>Whether the klogg-style log tools side panel is visible.</summary>
    [ObservableProperty] private bool _logToolsVisible;

    /// <summary>Which log-tools tab is showing.</summary>
    [ObservableProperty] private LogToolsTab _activeLogTab = LogToolsTab.Filter;

    partial void OnActiveLogTabChanged(LogToolsTab value)
    {
        OnPropertyChanged(nameof(IsFilterTab));
        OnPropertyChanged(nameof(IsSearchTab));
        OnPropertyChanged(nameof(IsMarksTab));
        OnPropertyChanged(nameof(IsHighlightersTab));
        RefreshActiveLogTab();
    }

    public bool IsFilterTab => ActiveLogTab == LogToolsTab.Filter;
    public bool IsSearchTab => ActiveLogTab == LogToolsTab.Search;
    public bool IsMarksTab => ActiveLogTab == LogToolsTab.Marks;
    public bool IsHighlightersTab => ActiveLogTab == LogToolsTab.Highlighters;

    // --- Filter (grep) pane ---

    [ObservableProperty] private string _filterText = "";
    [ObservableProperty] private bool _filterUsesRegex = true;
    [ObservableProperty] private bool _filterCaseSensitive;
    /// <summary>Invert: show lines that do NOT match (klogg inverse filter).</summary>
    [ObservableProperty] private bool _filterInverted;

    partial void OnFilterTextChanged(string value) => RunFilter();
    partial void OnFilterUsesRegexChanged(bool value) => RunFilter();
    partial void OnFilterCaseSensitiveChanged(bool value) => RunFilter();
    partial void OnFilterInvertedChanged(bool value) => RunFilter();

    public ObservableCollection<LogResultLine> FilterResults { get; } = new();

    // --- Search-results pane ---

    [ObservableProperty] private string _logSearchText = "";
    partial void OnLogSearchTextChanged(string value) => RunSearchResults();

    public ObservableCollection<LogResultLine> SearchResults { get; } = new();

    // --- Marks pane ---

    private readonly HashSet<int> _marked = new();

    /// <summary>Marked lines, for the view's mark strip renderer.</summary>
    public IReadOnlyCollection<int> MarkedLines => _marked;

    public ObservableCollection<LogResultLine> Marks { get; } = new();

    // --- Highlighters ---

    public ObservableCollection<LogHighlighterVm> Highlighters { get; } = new();

    // --- Follow mode (tail -f) ---

    [ObservableProperty] private bool _followMode;

    partial void OnFollowModeChanged(bool value)
    {
        if (value && !string.IsNullOrEmpty(FilePath))
        {
            ReloadFromDiskCommand.Execute(null);
            ScrollToEndRequested?.Invoke();
        }
    }

    // --- Events the view handles ---

    /// <summary>Raised to move the caret to a 1-based line and reveal it.</summary>
    public event Action<int>? JumpToLineRequested;
    /// <summary>Raised to scroll the caret to the end of the buffer (follow mode).</summary>
    public event Action? ScrollToEndRequested;
    /// <summary>Raised when the mark set changes so the view repaints the strip.</summary>
    public event Action? MarksChanged;
    /// <summary>Raised when a highlighter is added/removed/edited so the view re-renders.</summary>
    public event Action? HighlightersChanged;

    /// <summary>Wire up highlighters (load persisted, subscribe for persistence).
    /// Called once from the main constructor.</summary>
    private void InitLogTools()
    {
        foreach (var dto in LogHighlighterStore.Load())
            Highlighters.Add(Adopt(new LogHighlighterVm
            {
                Pattern = dto.Pattern,
                ColorHex = dto.ColorHex,
                CaseSensitive = dto.CaseSensitive,
                WholeLine = dto.WholeLine,
                Enabled = dto.Enabled,
            }));
        Highlighters.CollectionChanged += (_, _) => PersistHighlighters();
    }

    /// <summary>Subscribe a highlighter's change event to persistence + re-render.</summary>
    private LogHighlighterVm Adopt(LogHighlighterVm h)
    {
        h.Changed += () => { PersistHighlighters(); HighlightersChanged?.Invoke(); };
        return h;
    }

    private void PersistHighlighters()
    {
        LogHighlighterStore.Save(Highlighters.Select(h => new LogHighlighterDto
        {
            Pattern = h.Pattern,
            ColorHex = h.ColorHex,
            CaseSensitive = h.CaseSensitive,
            WholeLine = h.WholeLine,
            Enabled = h.Enabled,
        }));
        HighlightersChanged?.Invoke();
    }

    // --- Commands ---

    [RelayCommand]
    private void ToggleLogTools()
    {
        LogToolsVisible = !LogToolsVisible;
        if (LogToolsVisible) RefreshActiveLogTab();
    }

    [RelayCommand]
    private void ShowLogTab(LogToolsTab tab)
    {
        ActiveLogTab = tab;
        LogToolsVisible = true;
    }
    [RelayCommand]
    private void JumpToLine(LogResultLine? line)
    {
        if (line != null) JumpToLineRequested?.Invoke(line.LineNumber);
    }

    [RelayCommand]
    private void ToggleMarkAtCaret()
    {
        int line = CaretLine;
        if (!_marked.Add(line)) _marked.Remove(line);
        RebuildMarks();
        MarksChanged?.Invoke();
    }

    [RelayCommand]
    private void ClearMarks()
    {
        _marked.Clear();
        RebuildMarks();
        MarksChanged?.Invoke();
    }

    [RelayCommand]
    private void AddHighlighter()
    {
        var seed = string.IsNullOrEmpty(LogSearchText) ? FilterText : LogSearchText;
        var color = LogHighlighterVm.Palette[Highlighters.Count % LogHighlighterVm.Palette.Length];
        Highlighters.Add(Adopt(new LogHighlighterVm
        {
            Pattern = seed,
            ColorHex = color,
            CaseSensitive = FilterCaseSensitive,
        }));
        ActiveLogTab = LogToolsTab.Highlighters;
        LogToolsVisible = true;
        HighlightersChanged?.Invoke();
    }

    [RelayCommand]
    private void RemoveHighlighter(LogHighlighterVm? h)
    {
        if (h != null) Highlighters.Remove(h);
        HighlightersChanged?.Invoke();
    }

    // --- Result computation ---

    /// <summary>Recompute whichever result list the active tab shows.</summary>
    public void RefreshActiveLogTab()
    {
        switch (ActiveLogTab)
        {
            case LogToolsTab.Filter: RunFilter(); break;
            case LogToolsTab.Search: RunSearchResults(); break;
            case LogToolsTab.Marks: RebuildMarks(); break;
        }
    }

    /// <summary>Refresh visible result lists after the buffer text changes
    /// (open / reload / follow-mode append).</summary>
    public void RefreshLogToolsAfterTextChange()
    {
        if (!LogToolsVisible) return;
        if (ActiveLogTab == LogToolsTab.Filter) RunFilter();
        else if (ActiveLogTab == LogToolsTab.Search) RunSearchResults();
    }

    private void RunFilter()
    {
        FilterResults.Clear();
        if (string.IsNullOrEmpty(FilterText)) return;
        var matcher = new LineMatcher(FilterText, FilterUsesRegex, FilterCaseSensitive);
        int n = 0;
        foreach (var line in SplitLines(Text))
        {
            n++;
            bool hit = matcher.Matches(line);
            if (hit != FilterInverted)
                FilterResults.Add(new LogResultLine { LineNumber = n, Text = line });
        }
    }

    private void RunSearchResults()
    {
        SearchResults.Clear();
        if (string.IsNullOrEmpty(LogSearchText)) return;
        var matcher = new LineMatcher(LogSearchText, useRegex: true, caseSensitive: false);
        int n = 0;
        foreach (var line in SplitLines(Text))
        {
            n++;
            if (matcher.Matches(line))
                SearchResults.Add(new LogResultLine { LineNumber = n, Text = line });
        }
    }

    private void RebuildMarks()
    {
        Marks.Clear();
        var lines = SplitLines(Text);
        foreach (var ln in _marked.OrderBy(x => x))
            if (ln >= 1 && ln <= lines.Length)
                Marks.Add(new LogResultLine { LineNumber = ln, Text = lines[ln - 1] });
    }

    private static string[] SplitLines(string text) =>
        text.Replace("\r\n", "\n").Replace("\r", "\n").Split('\n');
}

/// <summary>Compiles a filter/search query once and tests lines against it.</summary>
internal sealed class LineMatcher
{
    private readonly Regex? _regex;
    private readonly string _literal;
    private readonly bool _caseSensitive;

    public LineMatcher(string query, bool useRegex, bool caseSensitive)
    {
        _caseSensitive = caseSensitive;
        if (useRegex)
        {
            var opts = RegexOptions.CultureInvariant;
            if (!caseSensitive) opts |= RegexOptions.IgnoreCase;
            try { _regex = new Regex(query, opts); } catch { _regex = null; }
            _literal = "";
        }
        else { _literal = query; }
    }

    public bool Matches(string line)
    {
        if (_regex != null) return _regex.IsMatch(line);
        if (string.IsNullOrEmpty(_literal)) return false;
        return line.IndexOf(_literal,
            _caseSensitive ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase) >= 0;
    }
}
