using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Models;
using System;

namespace RemoteStuff.ViewModels;

/// <summary>Base class for any open tab (terminal, SFTP, editor, MQTT, Redis…).</summary>
public abstract partial class TabViewModel : ViewModelBase
{
    [ObservableProperty] private string _title = "Tab";
    [ObservableProperty] private bool _isRunning = true;

    /// <summary>A user-supplied custom tab name. When set it overrides the auto-generated
    /// <see cref="Title"/>; when blank the tab falls back to its normal naming convention.</summary>
    [ObservableProperty] private string _customTitle = "";

    /// <summary>The name actually shown on the tab: the user's custom name when present,
    /// otherwise the auto-generated <see cref="Title"/>.</summary>
    public string DisplayTitle => string.IsNullOrWhiteSpace(CustomTitle) ? Title : CustomTitle;

    partial void OnTitleChanged(string value) => OnPropertyChanged(nameof(DisplayTitle));
    partial void OnCustomTitleChanged(string value) => OnPropertyChanged(nameof(DisplayTitle));

    /// <summary>An emoji/text glyph shown on the tab.</summary>
    public virtual string Glyph => "•";

    /// <summary>True for tabs that represent a remote connection (an ssh terminal),
    /// enabling Connect / Disconnect / Edit / Copy IP on the tab's right-click menu.</summary>
    public virtual bool SupportsConnection => false;

    /// <summary>True for tabs that expose an "Edit Connection Settings…" action.
    /// Defaults to <see cref="SupportsConnection"/> (ssh terminals); MQTT/Redis tabs
    /// override it so they can be re-pointed without the Connect/Disconnect/Copy-IP actions.</summary>
    public virtual bool SupportsEditConnection => SupportsConnection;

    /// <summary>The host/IP this tab connects to, when applicable.</summary>
    public virtual string? Host => null;

    /// <summary>Host + port this tab can be health-probed against (a TCP connect), or
    /// null for tabs with no network endpoint (local shell, browser, editor, …). Drives
    /// the workspace Connection Health dialog.</summary>
    public virtual (string Host, int Port)? ConnectionEndpoint => null;

    /// <summary>Show "Connect" in the tab menu (a disconnected remote tab).</summary>
    public bool ShowConnectAction => SupportsConnection && !IsRunning;

    /// <summary>Show "Disconnect" in the tab menu (a live remote tab).</summary>
    public bool ShowDisconnectAction => SupportsConnection && IsRunning;

    partial void OnIsRunningChanged(bool value)
    {
        OnPropertyChanged(nameof(ShowConnectAction));
        OnPropertyChanged(nameof(ShowDisconnectAction));
    }

    public Guid Id { get; } = Guid.NewGuid();

    /// <summary>The profile this tab was opened from, when applicable (for sidebar status).</summary>
    public Guid? ProfileId { get; set; }

    /// <summary>Which workspace (top-level tab collection) this tab belongs to.</summary>
    public Guid WorkspaceId { get; set; }

    /// <summary>Which edge this tab is docked to (Center = the main tab area).</summary>
    [ObservableProperty] private DockSide _dock = DockSide.Center;

    /// <summary>Whether this tab's center cell is shown. Every center tab stays
    /// mounted (so a browser tab's native web view is never torn down when you
    /// switch tabs); in single (non-tiled) mode only the selected tab's cell is
    /// visible. Mirrors the macOS app keeping all sessions alive in a ZStack.</summary>
    [ObservableProperty] private bool _isCellVisible = true;

    partial void OnIsCellVisibleChanged(bool value) => OnCellVisibilityChanged(value);

    /// <summary>Called when this tab's center cell is shown or hidden. Lets tabs that
    /// host a native control (e.g. a browser's web view, which the platform may tear
    /// down while the cell is hidden) restore themselves when they become visible.</summary>
    protected virtual void OnCellVisibilityChanged(bool visible) { }

    /// <summary>True when this tab lives in an edge drawer (not the center area).</summary>
    public bool IsDocked => Dock != DockSide.Center;

    /// <summary>Chevron pointing toward the docked edge, for the collapse button.</summary>
    public string CollapseGlyph => Dock switch
    {
        DockSide.Left => "\u21E4",   // ⇤ tuck to left edge
        DockSide.Right => "\u21E5",  // ⇥ tuck to right edge
        DockSide.Top => "\u2912",    // ⤒ tuck to top edge
        DockSide.Bottom => "\u2913", // ⤓ tuck to bottom edge
        _ => ""
    };

    partial void OnDockChanged(DockSide value)
    {
        OnPropertyChanged(nameof(IsDocked));
        OnPropertyChanged(nameof(CollapseGlyph));
    }

    public event Action<TabViewModel>? CloseRequested;

    /// <summary>Raised when the user asks to move this tab to a different dock edge.</summary>
    public event Action<TabViewModel, DockSide>? DockRequested;

    /// <summary>Raised when the user asks to open a duplicate of this tab.</summary>
    public event Action<TabViewModel>? DuplicateRequested;

    /// <summary>Colour themes offered on the tab's right-click menu (terminal tabs only).
    /// Each item carries its own apply command so the submenu needs no cross-popup binding.</summary>
    public virtual System.Collections.Generic.IReadOnlyList<ThemeMenuItem> ThemeMenuItems
        => System.Array.Empty<ThemeMenuItem>();

    /// <summary>Whether the "Theme" submenu applies to this tab.</summary>
    public virtual bool SupportsTheme => false;

    /// <summary>Optional per-tab accent colour (hex like <c>#4C8BF5</c>, empty = none).
    /// Set from the tab's "Tab Colour" right-click submenu and persisted with the
    /// workspace so a reopened workspace restores each tab's colour.</summary>
    [ObservableProperty] private string _tabColor = "";

    partial void OnTabColorChanged(string value)
    {
        OnPropertyChanged(nameof(TabColorBrush));
        OnPropertyChanged(nameof(HasTabColor));
    }

    /// <summary>True when this tab has an accent colour assigned.</summary>
    public bool HasTabColor => !string.IsNullOrWhiteSpace(TabColor);

    /// <summary>The accent colour as a brush (null when none), for the tab's colour chip.</summary>
    public Avalonia.Media.IBrush? TabColorBrush =>
        !string.IsNullOrWhiteSpace(TabColor) && Avalonia.Media.Color.TryParse(TabColor, out var c)
            ? new Avalonia.Media.SolidColorBrush(c) : null;

    /// <summary>Accent-colour options for the tab's "Tab Colour" submenu. Each carries a
    /// self-contained command so the menu binds to <c>ApplyCommand</c> directly without
    /// any <c>$parent</c> traversal across the submenu popup.</summary>
    public System.Collections.Generic.IReadOnlyList<TabColorMenuItem> TabColorMenuItems =>
        _tabColorMenuItems ??= BuildTabColorMenu();
    private System.Collections.Generic.IReadOnlyList<TabColorMenuItem>? _tabColorMenuItems;

    private System.Collections.Generic.IReadOnlyList<TabColorMenuItem> BuildTabColorMenu()
    {
        (string Name, string Hex)[] choices =
        {
            ("None", ""), ("Red", "#E5484D"), ("Orange", "#F5A623"), ("Yellow", "#F2D600"),
            ("Green", "#3FB950"), ("Blue", "#4C8BF5"), ("Purple", "#A26BF5"),
            ("Pink", "#EC6FB0"), ("Gray", "#8A8F98"),
        };
        var list = new System.Collections.Generic.List<TabColorMenuItem>();
        foreach (var (name, hex) in choices)
            list.Add(new TabColorMenuItem(name, hex, h => TabColor = h));
        return list;
    }

    /// <summary>Whether this tab exposes command snippets (terminal tabs only).</summary>
    public virtual bool HasSnippets => false;

    /// <summary>Whether this tab exposes typed-command history (terminal tabs only).</summary>
    public virtual bool HasHistory => false;

    /// <summary>Whether this is a web browser tab (its nav controls live in the
    /// shared dock-cell header instead of a per-tab toolbar).</summary>
    public virtual bool IsBrowserTab => false;

    /// <summary>Apply a colour theme to this tab (overridden by terminal tabs).</summary>
    protected virtual void OnThemeSelected(TerminalTheme theme) { }

    [RelayCommand]
    protected virtual void Close() => CloseRequested?.Invoke(this);

    [RelayCommand] private void DockCenter() => DockRequested?.Invoke(this, DockSide.Center);
    [RelayCommand] private void DockLeft() => DockRequested?.Invoke(this, DockSide.Left);
    [RelayCommand] private void DockRight() => DockRequested?.Invoke(this, DockSide.Right);
    [RelayCommand] private void DockTop() => DockRequested?.Invoke(this, DockSide.Top);
    [RelayCommand] private void DockBottom() => DockRequested?.Invoke(this, DockSide.Bottom);

    /// <summary>Ask the shell to open a duplicate of this tab (self-contained so the
    /// docked ⋮ menu can invoke it without any cross-popup <c>$parent</c> binding).</summary>
    [RelayCommand] private void Duplicate() => DuplicateRequested?.Invoke(this);

    /// <summary>Called when the tab is being permanently removed, to release resources.</summary>
    public virtual void Dispose() { }

    /// <summary>Capture this tab into a codable snapshot so it can be recreated when a
    /// saved workspace is reopened or the session is resumed. Returns null for tabs
    /// that can't be meaningfully rebuilt (documents, one-off setup terminals).</summary>
    public virtual RemoteStuff.Services.TabSnapshot? CreateSnapshot() => null;
}

/// <summary>A single entry in a tab's "Theme" submenu. Holds the display name and a
/// self-contained command, so the menu binds to <c>ApplyCommand</c> directly without
/// any <c>$parent</c> traversal across the submenu popup.</summary>
public sealed class ThemeMenuItem
{
    public string Name { get; }
    public IRelayCommand ApplyCommand { get; }

    public ThemeMenuItem(TerminalTheme theme, Action<TerminalTheme> apply)
    {
        Name = theme.Name;
        ApplyCommand = new RelayCommand(() => apply(theme));
    }
}

/// <summary>A single entry in a tab's "Tab Colour" submenu: a name, its hex value, a
/// swatch brush and a self-contained command that applies the colour to the tab.</summary>
public sealed class TabColorMenuItem
{
    public string Name { get; }
    public string Hex { get; }
    public Avalonia.Media.IBrush Swatch { get; }
    public IRelayCommand ApplyCommand { get; }

    public TabColorMenuItem(string name, string hex, Action<string> apply)
    {
        Name = name;
        Hex = hex;
        Swatch = !string.IsNullOrEmpty(hex) && Avalonia.Media.Color.TryParse(hex, out var c)
            ? new Avalonia.Media.SolidColorBrush(c)
            : Avalonia.Media.Brushes.Transparent;
        ApplyCommand = new RelayCommand(() => apply(hex));
    }
}
