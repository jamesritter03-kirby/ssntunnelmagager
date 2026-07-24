using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Models;
using RemoteStuff.Services;

namespace RemoteStuff.ViewModels;

public sealed partial class MainWindowViewModel : ViewModelBase
{
    private readonly ProfileStore _store;
    private readonly SecretStore _secrets;
    private readonly ZeroTierService _zeroTier;
    public AppSettings Settings { get; }

    public ObservableCollection<SshProfile> Profiles { get; } = new();
    public ObservableCollection<TabViewModel> Tabs { get; } = new();

    // ---- Workspaces (top-level saveable tab collections) ----
    public ObservableCollection<WorkspaceViewModel> Workspaces { get; } = new();
    [ObservableProperty] private WorkspaceViewModel? _currentWorkspace;
    // Closing the last workspace is allowed: it just empties that workspace (its
    // tabs are recorded in Recently Closed) and reveals the welcome screen, so the
    // ✕ is always offered.
    public bool CanCloseWorkspace => true;

    /// <summary>Saved workspace templates, mirrored for the Workspace menu's
    /// "Open / Delete Saved Workspace" submenus. Each item carries its own
    /// commands so the menu never binds a parameter across the popup boundary.</summary>
    public ObservableCollection<SavedWorkspaceMenuItem> SavedWorkspaces { get; } = new();
    public bool HasSavedWorkspaces => SavedWorkspaces.Count > 0;

    /// <summary>Saved workspace names offered as launch templates in the profile editor.</summary>
    private IReadOnlyList<string> SavedWorkspaceNames() =>
        _store.WorkspaceTemplates
            .Select(t => t.Name)
            .OrderBy(n => n, StringComparer.OrdinalIgnoreCase)
            .ToList();

    /// <summary>Repopulate <see cref="SavedWorkspaces"/> from the store (after a
    /// save / delete) so the Workspace menu stays current.</summary>
    private void RefreshSavedWorkspaces()
    {
        SavedWorkspaces.Clear();
        foreach (var t in _store.WorkspaceTemplates.OrderBy(w => w.Name, StringComparer.OrdinalIgnoreCase))
        {
            var template = t;
            SavedWorkspaces.Add(new SavedWorkspaceMenuItem(
                template.Name,
                new RelayCommand(() => OpenWorkspaceTemplate(template)),
                new RelayCommand(() => DeleteSavedWorkspaceTemplate(template))));
        }
        OnPropertyChanged(nameof(HasSavedWorkspaces));
    }

    /// <summary>Guards profile launches triggered while building a workspace
    /// template so those tabs land in the workspace being built instead of each
    /// spawning its own dedicated workspace.</summary>
    private bool _suppressWorkspaceRouting;

    /// <summary>When a launcher profile recreates its template, the primary connection
    /// tab is skipped (the profile opens its own configured ssh tab afterwards). This
    /// records the index in <see cref="Tabs"/> where that primary sat in the saved tab
    /// order, so the profile's own tab is moved back into place instead of landing last.</summary>
    private int? _pendingPrimaryTabIndex;

    /// <summary>The live tabs that belong to the current workspace.</summary>
    private IEnumerable<TabViewModel> WorkspaceTabs =>
        CurrentWorkspace is { } ws ? Tabs.Where(t => t.WorkspaceId == ws.Id) : Tabs;

    /// <summary>The current workspace's tabs shown as chips in the tab strip.
    /// Docked tabs are omitted — they live in their edge drawer instead.</summary>
    public IReadOnlyList<TabViewModel> WorkspaceTabList => WorkspaceTabs.Where(t => !t.IsDocked).ToList();
    public bool HasWorkspaceTabs => WorkspaceTabs.Any();

    /// <summary>Grouped, collapsible sidebar sections (Favourites + groups), Mac-style.</summary>
    public ObservableCollection<SidebarSectionViewModel> SidebarSections { get; } = new();

    /// <summary>Section titles the user has collapsed, preserved across rebuilds.</summary>
    private readonly HashSet<string> _collapsedSections = new(StringComparer.Ordinal);

    /// <summary>Live text filter for the sidebar (name / host / user / group).</summary>
    [ObservableProperty] private string _searchText = "";

    /// <summary>When true, only ZeroTier-online (or local) profiles are shown.</summary>
    [ObservableProperty] private bool _showOnlineOnly;

    /// <summary>When true, the profile sidebar is shown; when false it slides out.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SidebarWidth))]
    [NotifyPropertyChangedFor(nameof(SidebarToggleGlyph))]
    private bool _isSidebarVisible = true;

    /// <summary>User-adjustable width of the expanded sidebar (drag the edge to resize).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SidebarWidth))]
    private double _expandedSidebarWidth = 280;

    partial void OnExpandedSidebarWidthChanged(double value)
    {
        var clamped = Math.Clamp(value, 200, 560);
        if (Math.Abs(clamped - value) > 0.01)
        {
            ExpandedSidebarWidth = clamped;
            return;
        }
        // Remember the width across launches.
        Settings.SidebarWidth = clamped;
    }

    /// <summary>Target width for the sidebar (0 when collapsed) — animated in the view.</summary>
    public double SidebarWidth => IsSidebarVisible ? ExpandedSidebarWidth : 0;

    /// <summary>Chevron shown on the sidebar toggle button.</summary>
    public string SidebarToggleGlyph => IsSidebarVisible ? "\u276E" : "\u276F";

    [RelayCommand]
    private void ToggleSidebar() => IsSidebarVisible = !IsSidebarVisible;

    // ---- ZeroTier side panel (persists across workspaces, like the sidebar) ----

    private ZeroTierTabViewModel? _zeroTierPanel;

    /// <summary>The persistent ZeroTier browser panel (created on first use).</summary>
    public ZeroTierTabViewModel ZeroTierPanel => _zeroTierPanel ??= CreateZeroTierPanel();

    /// <summary>When true, the ZeroTier panel is shown; when false it is collapsed.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ZeroTierToggleGlyph))]
    private bool _isZeroTierVisible;

    /// <summary>Globe glyph used for the toolbar toggle button.</summary>
    public string ZeroTierToggleGlyph => "\U0001F310";

    [RelayCommand]
    private void ToggleZeroTier()
    {
        _ = ZeroTierPanel;               // ensure the panel VM exists
        IsZeroTierVisible = !IsZeroTierVisible;
    }

    [RelayCommand]
    private void HideZeroTier() => IsZeroTierVisible = false;

    private ZeroTierTabViewModel CreateZeroTierPanel()
    {
        var zt = new ZeroTierTabViewModel(_zeroTier, Settings);
        zt.DeviceActionRequested += OnZeroTierDeviceAction;
        return zt;
    }

    private void OnZeroTierDeviceAction(ZtDeviceAction action, string name, string host,
                                        string username, string password)
    {
        var user = string.IsNullOrWhiteSpace(username) ? "root" : username.Trim();
        var pass = string.IsNullOrEmpty(password) ? null : password;
        switch (action)
        {
            case ZtDeviceAction.NewProfile:
            {
                var profile = new SshProfile { Name = name, Host = host, Username = user };
                var editor = new ProfileEditorViewModel(profile, isNew: true, Save, hasSavedPassword: false, SavedWorkspaceNames());
                EditProfileRequested?.Invoke(editor);
                break;
            }
            case ZtDeviceAction.SshTerminal:
                OpenSession(AdHocProfile(name, host, user), pass);
                break;
            case ZtDeviceAction.Sftp:
                OpenSftpTab(AdHocProfile(name, host, user), pass);
                break;
            case ZtDeviceAction.Vnc:
                OpenVncDirectTab(host, 5900, $"{name} · VNC");
                break;
            case ZtDeviceAction.Mqtt:
                OpenMqttTab(host, 1883, string.IsNullOrWhiteSpace(username) ? null : user, pass, $"{name} · MQTT");
                break;
            case ZtDeviceAction.Redis:
                OpenRedisTab(host, 6379, pass, $"{name} · Redis");
                break;
        }
    }

    /// <summary>Build a throwaway SSH profile targeting a ZeroTier device by IP.</summary>
    private static SshProfile AdHocProfile(string name, string host, string username) =>
        new() { Name = string.IsNullOrWhiteSpace(name) ? host : name, Host = host, Username = username };

    /// <summary>The currently selected sidebar row (drives <see cref="SelectedProfile"/>).</summary>
    [ObservableProperty] private ProfileRowViewModel? _selectedRow;

    /// <summary>True when the sidebar has no rows after filtering.</summary>
    public bool SidebarEmpty => SidebarSections.Count == 0;

    /// <summary>Total number of saved profiles (bottom-bar counter).</summary>
    public int TotalProfileCount => _store.Profiles.Count;

    /// <summary>Number of profiles with a live session (bottom-bar counter).</summary>
    public int ConnectedProfileCount =>
        SidebarSections.SelectMany(s => s.Rows).Select(r => r.Profile.Id).Distinct()
            .Count(id => Tabs.Any(t => t.ProfileId == id && t.IsRunning));

    /// <summary>Number of ZeroTier-online profiles (bottom-bar counter).</summary>
    public int OnlineProfileCount =>
        _store.Profiles.Count(p => !p.IsLocal && _zeroTier.IsHostOnline(p.Host));

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(EditProfileCommand))]
    [NotifyCanExecuteChangedFor(nameof(DuplicateProfileCommand))]
    [NotifyCanExecuteChangedFor(nameof(DeleteProfileCommand))]
    [NotifyCanExecuteChangedFor(nameof(ConnectCommand))]
    [NotifyCanExecuteChangedFor(nameof(OpenSftpCommand))]
    [NotifyCanExecuteChangedFor(nameof(OpenVncCommand))]
    [NotifyCanExecuteChangedFor(nameof(SetupPasswordlessLoginCommand))]
    private SshProfile? _selectedProfile;
    [ObservableProperty] private TabViewModel? _selectedTab;

    /// <summary>The live <c>ssh</c> command preview for the selected profile.</summary>
    [ObservableProperty] private string _commandPreview = "";

    /// <summary>True when a session tab is selected (show the terminal instead of the detail pane).</summary>
    public bool HasSelectedTab => SelectedTab != null;
    public bool ShowDetail => SelectedTab == null;
    public bool HasTabs => Tabs.Count > 0;

    /// <summary>The welcome screen shows when the current workspace has no tabs and
    /// no profile is selected — a set of quick starting points, mirroring the macOS
    /// app's empty-workspace welcome view.</summary>
    public bool ShowWelcome => !HasWorkspaceTabs && SelectedProfile == null;

    /// <summary>The plain "select a profile" hint shows only when the detail pane is
    /// otherwise empty (no profile, and the welcome screen isn't showing).</summary>
    public bool ShowSelectProfileHint => SelectedProfile == null && !ShowWelcome;

    /// <summary>Whether any profiles exist (drives the welcome screen's Profiles list).</summary>
    public bool HasProfiles => Profiles.Count > 0;

    /// <summary>When true, all open tabs are shown side-by-side in a grid.</summary>
    [ObservableProperty] private bool _isTiled;
    public bool ShowSingleTab => HasSelectedTab && !IsTiled;
    public bool ShowTiled => IsTiled && HasTabs;

    // ---- Docking: center + four edge drawers ----

    private double _leftW = 340, _rightW = 340, _topH = 220, _bottomH = 220;

    // Per-edge collapsed state: a collapsed drawer shrinks to a thin re-open bar.
    private bool _leftCollapsed, _rightCollapsed, _topCollapsed, _bottomCollapsed;
    private const double CollapsedSize = 26;

    public IReadOnlyList<TabViewModel> CenterTabs => WorkspaceTabs.Where(t => t.Dock == DockSide.Center).ToList();
    public IReadOnlyList<TabViewModel> LeftTabs => WorkspaceTabs.Where(t => t.Dock == DockSide.Left).ToList();
    public IReadOnlyList<TabViewModel> RightTabs => WorkspaceTabs.Where(t => t.Dock == DockSide.Right).ToList();
    public IReadOnlyList<TabViewModel> TopTabs => WorkspaceTabs.Where(t => t.Dock == DockSide.Top).ToList();
    public IReadOnlyList<TabViewModel> BottomTabs => WorkspaceTabs.Where(t => t.Dock == DockSide.Bottom).ToList();

    public bool HasLeftTabs => LeftTabs.Count > 0;
    public bool HasRightTabs => RightTabs.Count > 0;
    public bool HasTopTabs => TopTabs.Count > 0;
    public bool HasBottomTabs => BottomTabs.Count > 0;

    // Drawer content is shown only when the edge has tabs and isn't collapsed.
    public bool ShowLeftDrawer => HasLeftTabs && !_leftCollapsed;
    public bool ShowRightDrawer => HasRightTabs && !_rightCollapsed;
    public bool ShowTopDrawer => HasTopTabs && !_topCollapsed;
    public bool ShowBottomDrawer => HasBottomTabs && !_bottomCollapsed;

    // A slim re-open bar takes the drawer's place while it's collapsed.
    public bool ShowLeftReopen => HasLeftTabs && _leftCollapsed;
    public bool ShowRightReopen => HasRightTabs && _rightCollapsed;
    public bool ShowTopReopen => HasTopTabs && _topCollapsed;
    public bool ShowBottomReopen => HasBottomTabs && _bottomCollapsed;

    // Grid sizes for the drawers (0 collapses the column/row when empty; a thin
    // bar when the drawer is collapsed). Two-way bound so a GridSplitter drag persists.
    public Avalonia.Controls.GridLength LeftDockWidth
    {
        get => !HasLeftTabs ? new Avalonia.Controls.GridLength(0)
             : _leftCollapsed ? new Avalonia.Controls.GridLength(CollapsedSize)
             : new Avalonia.Controls.GridLength(_leftW);
        set { if (value.IsAbsolute && value.Value > CollapsedSize) _leftW = value.Value; OnPropertyChanged(); }
    }
    public Avalonia.Controls.GridLength RightDockWidth
    {
        get => !HasRightTabs ? new Avalonia.Controls.GridLength(0)
             : _rightCollapsed ? new Avalonia.Controls.GridLength(CollapsedSize)
             : new Avalonia.Controls.GridLength(_rightW);
        set { if (value.IsAbsolute && value.Value > CollapsedSize) _rightW = value.Value; OnPropertyChanged(); }
    }
    public Avalonia.Controls.GridLength TopDockHeight
    {
        get => !HasTopTabs ? new Avalonia.Controls.GridLength(0)
             : _topCollapsed ? new Avalonia.Controls.GridLength(CollapsedSize)
             : new Avalonia.Controls.GridLength(_topH);
        set { if (value.IsAbsolute && value.Value > CollapsedSize) _topH = value.Value; OnPropertyChanged(); }
    }
    public Avalonia.Controls.GridLength BottomDockHeight
    {
        get => !HasBottomTabs ? new Avalonia.Controls.GridLength(0)
             : _bottomCollapsed ? new Avalonia.Controls.GridLength(CollapsedSize)
             : new Avalonia.Controls.GridLength(_bottomH);
        set { if (value.IsAbsolute && value.Value > CollapsedSize) _bottomH = value.Value; OnPropertyChanged(); }
    }

    [RelayCommand] private void ToggleLeftDock() { _leftCollapsed = !_leftCollapsed; RecomputeDocks(); }
    [RelayCommand] private void ToggleRightDock() { _rightCollapsed = !_rightCollapsed; RecomputeDocks(); }
    [RelayCommand] private void ToggleTopDock() { _topCollapsed = !_topCollapsed; RecomputeDocks(); }
    [RelayCommand] private void ToggleBottomDock() { _bottomCollapsed = !_bottomCollapsed; RecomputeDocks(); }

    /// <summary>Collapse the edge a docked tab lives on (from its header chevron).</summary>
    [RelayCommand]
    private void CollapseTabDock(TabViewModel? tab)
    {
        switch (tab?.Dock)
        {
            case DockSide.Left: _leftCollapsed = true; break;
            case DockSide.Right: _rightCollapsed = true; break;
            case DockSide.Top: _topCollapsed = true; break;
            case DockSide.Bottom: _bottomCollapsed = true; break;
            default: return;
        }
        RecomputeDocks();
    }

    private void RecomputeDocks()
    {
        OnPropertyChanged(nameof(CenterTabs));
        OnPropertyChanged(nameof(LeftTabs));
        OnPropertyChanged(nameof(RightTabs));
        OnPropertyChanged(nameof(TopTabs));
        OnPropertyChanged(nameof(BottomTabs));
        OnPropertyChanged(nameof(HasLeftTabs));
        OnPropertyChanged(nameof(HasRightTabs));
        OnPropertyChanged(nameof(HasTopTabs));
        OnPropertyChanged(nameof(HasBottomTabs));
        OnPropertyChanged(nameof(ShowLeftDrawer));
        OnPropertyChanged(nameof(ShowRightDrawer));
        OnPropertyChanged(nameof(ShowTopDrawer));
        OnPropertyChanged(nameof(ShowBottomDrawer));
        OnPropertyChanged(nameof(ShowLeftReopen));
        OnPropertyChanged(nameof(ShowRightReopen));
        OnPropertyChanged(nameof(ShowTopReopen));
        OnPropertyChanged(nameof(ShowBottomReopen));
        OnPropertyChanged(nameof(LeftDockWidth));
        OnPropertyChanged(nameof(RightDockWidth));
        OnPropertyChanged(nameof(TopDockHeight));
        OnPropertyChanged(nameof(BottomDockHeight));
        OnPropertyChanged(nameof(VisibleTabs));
        OnPropertyChanged(nameof(WorkspaceTabList));
        OnPropertyChanged(nameof(HasWorkspaceTabs));
        OnPropertyChanged(nameof(ShowWelcome));
        OnPropertyChanged(nameof(ShowSelectProfileHint));
        OnPropertyChanged(nameof(HasWorkspaceServer));
        OnPropertyChanged(nameof(WorkspaceServerName));
        OnPropertyChanged(nameof(NewSftpHereLabel));
        OnPropertyChanged(nameof(NewVncHereLabel));
        OnPropertyChanged(nameof(NewTerminalHereLabel));
        SyncCenterCells();
    }

    /// <summary>
    /// Every center tab is hosted here at once (each terminal/browser control is
    /// hosted exactly once — center tabs never also live in a dock). In single mode
    /// only the selected cell is shown (see <see cref="RefreshCellVisibility"/>); in
    /// tiled mode every cell shows. Keeping them all mounted means a browser tab's
    /// native web view survives tab switches instead of blanking out.
    /// </summary>
    public IReadOnlyList<TabViewModel> VisibleTabs => CenterTabs;

    /// <summary>The live, order-stable collection the center grid binds to. It is
    /// reconciled in place (add / remove / move) only when the set of center tabs
    /// actually changes — never on mere selection changes — so switching tabs keeps
    /// each cell's control (notably a browser's native web view) mounted.</summary>
    public ObservableCollection<TabViewModel> CenterCells { get; } = new();

    /// <summary>Reconcile <see cref="CenterCells"/> with the current center tabs
    /// without needlessly recreating containers, then refresh which cells show.</summary>
    private void SyncCenterCells()
    {
        // Include EVERY workspace's center tabs, not just the current one's, so a
        // browser tab's native web view is never unmounted (and permanently blanked)
        // when switching workspaces. Cells belonging to other workspaces stay mounted
        // but hidden via IsCellVisible (see RefreshCellVisibility).
        var target = Tabs.Where(t => t.Dock == DockSide.Center).ToList();
        for (var i = CenterCells.Count - 1; i >= 0; i--)
            if (!target.Contains(CenterCells[i]))
                CenterCells.RemoveAt(i);
        for (var i = 0; i < target.Count; i++)
        {
            var t = target[i];
            var cur = CenterCells.IndexOf(t);
            if (cur < 0) CenterCells.Insert(i, t);
            else if (cur != i) CenterCells.Move(cur, i);
        }
        RefreshCellVisibility();
    }

    /// <summary>Recompute which center cells are shown: all when tiling, otherwise
    /// just the selected tab. Docked tabs are always shown (in their drawer).</summary>
    private void RefreshCellVisibility()
    {
        // CenterCells now spans all workspaces (so web views stay mounted), so a center
        // cell is only shown when it belongs to the current workspace AND is either the
        // selected tab or we're tiling. Cells from other workspaces are hidden, which
        // also lets the UniformGrid collapse to just the visible ones.
        var wsId = CurrentWorkspace?.Id;
        foreach (var t in CenterCells)
            t.IsCellVisible = t.WorkspaceId == wsId && (IsTiled || t == SelectedTab);
    }

    public string StoragePath => _store.StoragePath;

    /// <summary>Raised so the view can present the profile editor. Bool = isNew.</summary>
    public event Action<ProfileEditorViewModel>? EditProfileRequested;
    public event Action<SettingsViewModel>? SettingsRequested;
    public event Action? KnownHostsRequested;
    public event Action? HelpRequested;
    public event Action<DeveloperViewModel>? DeveloperToolsRequested;
    public event Action<WorkspaceStatsViewModel>? WorkspaceStatsRequested;
    public event Action<ProfileComparisonViewModel>? CompareProfilesRequested;
    public event Action<GitSyncViewModel>? GitSyncRequested;
    public event Action<string>? CopyToClipboardRequested;

    /// <summary>Open the Connection Health dialog for a workspace.</summary>
    public void ShowWorkspaceStats(WorkspaceViewModel ws)
    {
        var vm = new WorkspaceStatsViewModel(ws.Name, () => Tabs.Where(t => t.WorkspaceId == ws.Id).ToList());
        WorkspaceStatsRequested?.Invoke(vm);
    }

    /// <summary>Ask the view for a file to import; returns the chosen path or null.</summary>
    public event Func<Task<string?>>? ImportFileRequested;
    /// <summary>Ask the view for a save path; returns the chosen path or null.</summary>
    public event Func<string, Task<string?>>? ExportFileRequested;

    /// <summary>A transient status message shown in the status bar.</summary>
    [ObservableProperty] private string _statusMessage = "";

    // ---- Command palette ----
    [ObservableProperty] private bool _isPaletteOpen;
    [ObservableProperty] private string _paletteQuery = "";
    [ObservableProperty] private PaletteItem? _selectedPaletteItem;
    public ObservableCollection<PaletteItem> PaletteResults { get; } = new();

    private void SetStatus(string message)
    {
        StatusMessage = message;
        var token = ++_statusToken;
        Avalonia.Threading.DispatcherTimer.RunOnce(() =>
        {
            if (token == _statusToken) StatusMessage = "";
        }, TimeSpan.FromSeconds(5));
    }
    private int _statusToken;

    public MainWindowViewModel(ProfileStore store, SecretStore secrets)
        : this(store, secrets, new AppSettings()) { }

    public MainWindowViewModel(ProfileStore store, SecretStore secrets, AppSettings settings)
    {
        _store = store;
        _secrets = secrets;
        Settings = settings;
        _expandedSidebarWidth = Math.Clamp(settings.SidebarWidth, 200, 560);
        _zeroTier = new ZeroTierService(secrets);
        _zeroTier.Updated += () => Avalonia.Threading.Dispatcher.UIThread.Post(RecomputeConnections);

        // Start with a single default workspace.
        var first = new WorkspaceViewModel(this, Guid.NewGuid(), "Workspace 1") { IsCurrent = true };
        Workspaces.Add(first);
        _currentWorkspace = first;
        Workspaces.CollectionChanged += (_, __) => OnPropertyChanged(nameof(CanCloseWorkspace));

        Tabs.CollectionChanged += (_, e) =>
        {
            OnPropertyChanged(nameof(HasTabs));
            OnPropertyChanged(nameof(ShowTiled));
            OnPropertyChanged(nameof(VisibleTabs));
            SyncCenterCells();
            if (e.NewItems != null)
                foreach (TabViewModel t in e.NewItems)
                {
                    if (t.WorkspaceId == Guid.Empty && CurrentWorkspace is { } ws)
                        t.WorkspaceId = ws.Id;
                    t.PropertyChanged += OnTabPropertyChanged;
                    t.DockRequested += OnTabDockRequested;
                    t.DuplicateRequested += OnTabDuplicateRequested;
                    if (t is TerminalTabViewModel term)
                        term.Terminal.UserInput += OnTerminalUserInput;
                }
            if (e.OldItems != null)
                foreach (TabViewModel t in e.OldItems)
                {
                    t.PropertyChanged -= OnTabPropertyChanged;
                    t.DockRequested -= OnTabDockRequested;
                    t.DuplicateRequested -= OnTabDuplicateRequested;
                    if (t is TerminalTabViewModel term)
                        term.Terminal.UserInput -= OnTerminalUserInput;
                }
            RecomputeConnections();
            RecomputeDocks();
            RefreshEditorCompareTargets();
        };
        ReloadProfiles();
        RefreshSavedWorkspaces();

        // Do NOT auto-select a profile at launch: an empty workspace should open on
        // the welcome screen (ShowWelcome requires SelectedProfile == null). Selecting
        // the first profile here would show its detail pane and hide the welcome page.
    }

    private void OnTabPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(TabViewModel.IsRunning))
            RecomputeConnections();
        else if (e.PropertyName == nameof(TabViewModel.Dock))
            RecomputeDocks();
    }

    private void OnTabDockRequested(TabViewModel tab, DockSide side)
    {
        tab.Dock = side;               // triggers RecomputeDocks via PropertyChanged
        if (side == DockSide.Center)
            SelectedTab = tab;
    }

    private void OnTabDuplicateRequested(TabViewModel tab) => DuplicateTab(tab);

    /// <summary>Mark sidebar rows connected when a live session for their profile is open.</summary>
    private void RecomputeConnections()
    {
        var connected = Tabs
            .Where(t => t is { ProfileId: not null, IsRunning: true })
            .Select(t => t.ProfileId!.Value)
            .ToHashSet();

        foreach (var section in SidebarSections)
            foreach (var row in section.Rows)
            {
                row.IsConnected = connected.Contains(row.Profile.Id);
                row.IsOnline = _zeroTier.IsHostOnline(row.Profile.Host);
            }
        OnPropertyChanged(nameof(ConnectedProfileCount));
        ConnectionsChanged?.Invoke();
    }

    /// <summary>Raised whenever live-session state changes (drives the tray checkmarks/badge).</summary>
    public event Action? ConnectionsChanged;

    /// <summary>True when the given profile has at least one live session.</summary>
    public bool IsProfileConnected(Guid profileId) =>
        Tabs.Any(t => t.ProfileId == profileId && t.IsRunning);

    /// <summary>Number of live terminal sessions across all workspaces (tray badge).</summary>
    public int LiveSessionCount => Tabs.OfType<TerminalTabViewModel>().Count(t => t.IsRunning);

    partial void OnSearchTextChanged(string value) => RebuildSidebar();

    partial void OnShowOnlineOnlyChanged(bool value) => RebuildSidebar();

    partial void OnSelectedRowChanged(ProfileRowViewModel? value)
    {
        // Keep the detail pane / toolbar commands in sync with the sidebar pick.
        if (value?.Profile.Id != SelectedProfile?.Id)
            SelectedProfile = value?.Profile;
    }

    /// <summary>
    /// Rebuild the grouped sidebar from the store, applying the search filter and
    /// preserving collapse state and the current selection.
    /// </summary>
    private void RebuildSidebar()
    {
        var selectedId = SelectedRow?.Profile.Id ?? SelectedProfile?.Id;

        SidebarSections.Clear();

        var q = SearchText.Trim();
        bool Matches(SshProfile p) =>
            q.Length == 0
            || p.Name.Contains(q, StringComparison.OrdinalIgnoreCase)
            || p.Host.Contains(q, StringComparison.OrdinalIgnoreCase)
            || p.Username.Contains(q, StringComparison.OrdinalIgnoreCase)
            || p.Group.Contains(q, StringComparison.OrdinalIgnoreCase);

        bool OnlineOk(SshProfile p) =>
            !ShowOnlineOnly || p.IsLocal || _zeroTier.IsHostOnline(p.Host);

        // Preserve the manual (persisted) store order so drag/move reordering sticks.
        var filtered = _store.Profiles.Where(p => Matches(p) && OnlineOk(p)).ToList();

        // Favourites first (they also still appear in their group), in store order.
        var favourites = filtered.Where(p => p.IsFavorite).ToList();
        if (favourites.Count > 0)
            AddSection("Favourites", "\u2605", favourites);

        // Named groups (alphabetical), then the ungrouped bucket last; rows keep store order.
        var groups = filtered
            .GroupBy(p => p.Group?.Trim() ?? "")
            .OrderBy(g => g.Key.Length == 0)                       // ungrouped last
            .ThenBy(g => g.Key, StringComparer.OrdinalIgnoreCase);

        foreach (var g in groups)
        {
            var title = g.Key.Length == 0 ? "Profiles" : g.Key;
            AddSection(title, "", g);
        }

        OnPropertyChanged(nameof(SidebarEmpty));
        RaiseSidebarCounts();
        RecomputeConnections();

        // Reselect the same profile if it still exists after the rebuild.
        if (selectedId is { } id)
            SelectedRow = SidebarSections
                .SelectMany(s => s.Rows)
                .FirstOrDefault(r => r.Profile.Id == id);
    }

    private void AddSection(string title, string glyph, IEnumerable<SshProfile> profiles)
    {
        var section = new SidebarSectionViewModel(title, glyph, this)
        {
            IsExpanded = !_collapsedSections.Contains(title)
        };
        foreach (var p in profiles)
            section.Rows.Add(new ProfileRowViewModel(p, this));
        section.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName != nameof(SidebarSectionViewModel.IsExpanded)) return;
            if (section.IsExpanded) _collapsedSections.Remove(section.Title);
            else _collapsedSections.Add(section.Title);
        };
        SidebarSections.Add(section);
    }

    /// <summary>Expand every profile group in the sidebar (right-click menu action).</summary>
    [RelayCommand]
    private void ExpandAllGroups()
    {
        foreach (var section in SidebarSections) section.IsExpanded = true;
    }

    /// <summary>Collapse every profile group in the sidebar (right-click menu action).</summary>
    [RelayCommand]
    private void CollapseAllGroups()
    {
        foreach (var section in SidebarSections) section.IsExpanded = false;
    }

    /// <summary>Notify the bottom-bar counters after a rebuild or connection change.</summary>
    private void RaiseSidebarCounts()
    {
        OnPropertyChanged(nameof(TotalProfileCount));
        OnPropertyChanged(nameof(ConnectedProfileCount));
        OnPropertyChanged(nameof(OnlineProfileCount));
    }

    /// <summary>
    /// Reorder a sidebar row up or down by swapping it with its visible neighbour in the
    /// same section (persisted to the store). <paramref name="delta"/> is -1 (up) or +1 (down).
    /// </summary>
    public void MoveRow(ProfileRowViewModel row, int delta)
    {
        var section = SidebarSections.FirstOrDefault(s => s.Rows.Contains(row));
        if (section is null) return;
        var idx = section.Rows.IndexOf(row);
        var target = idx + delta;
        if (target < 0 || target >= section.Rows.Count) return;
        var other = section.Rows[target];
        if (_store.Swap(row.Profile.Id, other.Profile.Id))
            RebuildSidebar();
    }

    // ---- Sidebar row actions (invoked from ProfileRowViewModel) ----

    public void ConnectRow(ProfileRowViewModel row)
    {
        SelectedRow = row;
        OpenSession(row.Profile);
    }

    public void DisconnectRow(ProfileRowViewModel row)
    {
        var open = Tabs
            .Where(t => t.ProfileId == row.Profile.Id && t.IsRunning)
            .ToList();
        foreach (var t in open)
            t.CloseCommand.Execute(null);
    }

    public void SftpRow(ProfileRowViewModel row)
    {
        SelectedRow = row;
        if (!row.Profile.IsLocal)
            OpenSftpTab(row.Profile);
    }

    public void EditRow(ProfileRowViewModel row)
    {
        SelectedRow = row;
        EditProfileCommand.Execute(null);
    }

    public void DuplicateRow(ProfileRowViewModel row)
    {
        var copy = _store.Duplicate(row.Profile);
        ReloadProfiles();
        SelectedProfile = Profiles.FirstOrDefault(x => x.Id == copy.Id);
    }

    public void ToggleFavoriteRow(ProfileRowViewModel row)
    {
        row.Profile.IsFavorite = !row.Profile.IsFavorite;
        _store.Update(row.Profile);
        row.RefreshFavorite();
        ReloadProfiles();
    }

    /// <summary>Copy a profile's host/IP address to the clipboard.</summary>
    public void CopyIpRow(ProfileRowViewModel row)
    {
        var host = row.Profile.Host?.Trim();
        if (!string.IsNullOrWhiteSpace(host))
        {
            CopyToClipboardRequested?.Invoke(host);
            StatusMessage = $"Copied {host}";
        }
    }

    public void DeleteRow(ProfileRowViewModel row)
    {
        _store.Delete(row.Profile);
        ReloadProfiles();
        SelectedProfile = Profiles.FirstOrDefault();
    }

    [RelayCommand]
    private void ClearSearch() => SearchText = "";

    private void ReloadProfiles()
    {
        Profiles.Clear();
        // Favourites first, then by group, then name — a lightweight sidebar order.
        var ordered = _store.Profiles
            .OrderByDescending(p => p.IsFavorite)
            .ThenBy(p => p.Group, StringComparer.OrdinalIgnoreCase)
            .ThenBy(p => p.Name, StringComparer.OrdinalIgnoreCase);
        foreach (var p in ordered)
            Profiles.Add(p);

        RebuildProfileMenus();
        RebuildSidebar();
    }

    partial void OnSelectedProfileChanged(SshProfile? value)
    {
        CommandPreview = value == null ? "" : SshCommandBuilder.CommandPreview(value);
        OnPropertyChanged(nameof(ShowWelcome));
        OnPropertyChanged(nameof(ShowSelectProfileHint));

        // Keep the sidebar highlight in sync when selection changes elsewhere.
        if (value?.Id != SelectedRow?.Profile.Id)
            SelectedRow = SidebarSections
                .SelectMany(s => s.Rows)
                .FirstOrDefault(r => r.Profile.Id == value?.Id);
    }

    partial void OnSelectedTabChanged(TabViewModel? value)
    {
        OnPropertyChanged(nameof(HasSelectedTab));
        OnPropertyChanged(nameof(ShowDetail));
        OnPropertyChanged(nameof(ShowSingleTab));
        OnPropertyChanged(nameof(VisibleTabs));
        RefreshCellVisibility();
        // Remember the active tab per workspace so switching workspaces restores it.
        if (value is not null && Workspaces.FirstOrDefault(w => w.Id == value.WorkspaceId) is { } ws)
            ws.LastSelectedTabId = value.Id;
    }

    partial void OnIsTiledChanged(bool value)
    {
        OnPropertyChanged(nameof(ShowSingleTab));
        OnPropertyChanged(nameof(ShowTiled));
        OnPropertyChanged(nameof(VisibleTabs));
        RefreshCellVisibility();
    }

    [RelayCommand]
    private void ToggleTile() => IsTiled = !IsTiled;

    // ---- Profile CRUD ----

    [RelayCommand]
    private void NewProfile()
    {
        var editor = new ProfileEditorViewModel(new SshProfile(), isNew: true, Save, hasSavedPassword: false, SavedWorkspaceNames());
        EditProfileRequested?.Invoke(editor);
    }

    [RelayCommand]
    private void NewLocalShell()
    {
        OpenSession(new SshProfile
        {
            Name = "Local Shell",
            IsLocal = true,
            Theme = string.IsNullOrEmpty(Settings.DefaultTerminalTheme)
                ? TerminalTheme.DefaultId
                : Settings.DefaultTerminalTheme,
            FontSize = Settings.DefaultTerminalFontSize > 0
                ? Settings.DefaultTerminalFontSize
                : TerminalFontMetrics.Default,
        });
    }

    [RelayCommand(CanExecute = nameof(HasSelection))]
    private void EditProfile()
    {
        if (SelectedProfile is not { } p) return;
        var editor = new ProfileEditorViewModel(p.Clone(), isNew: false, Save, _secrets.Has(p.Id), SavedWorkspaceNames());
        EditProfileRequested?.Invoke(editor);
    }

    [RelayCommand(CanExecute = nameof(HasSelection))]
    private void DuplicateProfile()
    {
        if (SelectedProfile is not { } p) return;
        var copy = _store.Duplicate(p);
        ReloadProfiles();
        SelectedProfile = Profiles.FirstOrDefault(x => x.Id == copy.Id);
    }

    [RelayCommand(CanExecute = nameof(HasSelection))]
    private void DeleteProfile()
    {
        if (SelectedProfile is not { } p) return;
        _store.Delete(p);
        ReloadProfiles();
        SelectedProfile = Profiles.FirstOrDefault();
    }

    private bool HasSelection() => SelectedProfile != null;

    private bool CanSetupPasswordless() => SelectedProfile is { IsLocal: false };

    /// <summary>
    /// Copy this profile's public key to the server with <c>ssh-copy-id</c> in a
    /// dedicated terminal tab, generating an ed25519 key first if none exists.
    /// </summary>
    [RelayCommand(CanExecute = nameof(CanSetupPasswordless))]
    private void SetupPasswordlessLogin()
    {
        if (SelectedProfile is not { IsLocal: false } profile) return;

        var existing = SshCopyIdBuilder.PublicKey(profile);
        var generateKey = existing is null;
        var publicKey = existing ?? SshCopyIdBuilder.DefaultGeneratedPublicKey();
        var script = SshCopyIdBuilder.SetupScript(profile, publicKey, generateKey);

        var shell = Environment.GetEnvironmentVariable("SHELL")
                    ?? (OperatingSystem.IsMacOS() ? "/bin/zsh" : "/bin/bash");

        var tab = new TerminalTabViewModel(
            title: $"Key setup · {profile.Name}",
            executable: shell,
            args: new[] { "-c", script },
            env: null,
            workingDirectory: null,
            runOnConnect: null,
            fontSize: profile.FontSize,
            theme: TerminalTheme.ById(profile.Theme),
            snippets: profile.Snippets,
            autoPassword: null);

        tab.CloseRequested += CloseTab;
        Tabs.Add(tab);
        SelectedTab = tab;
    }
    private void Save(SshProfile edited, bool isNew)
    {
        if (edited.PendingPassword is { } pw)
        {
            _secrets.Set(edited.Id, string.IsNullOrEmpty(pw) ? null : pw);
            edited.PendingPassword = null;
        }

        // Per-forward service passwords live in the encrypted store, keyed by the
        // forward's Id. Null = leave unchanged; empty = clear.
        foreach (var f in edited.Forwards)
        {
            if (f.PendingServicePassword is { } sp)
            {
                _secrets.Set(f.Id, string.IsNullOrEmpty(sp) ? null : sp);
                f.PendingServicePassword = null;
            }
        }

        if (isNew) _store.Add(edited);
        else _store.Update(edited);
        ReloadProfiles();
        SelectedProfile = Profiles.FirstOrDefault(x => x.Id == edited.Id);
    }

    [RelayCommand]
    private void CopyCommandPreview()
    {
        if (!string.IsNullOrEmpty(CommandPreview))
            CopyToClipboardRequested?.Invoke(CommandPreview);
    }

    // ---- Connect ----

    [RelayCommand(CanExecute = nameof(HasSelection))]
    private void Connect()
    {
        if (SelectedProfile is { } p)
            OpenSession(p);
    }

    public void OpenSession(SshProfile profile, string? adHocPassword = null, string? runOnConnectOverride = null,
        string? themeOverride = null, double? fontOverride = null)
    {
        // Keep an ad-hoc connection's password in the encrypted secret store, keyed
        // by its (stable) profile id, so it survives workspace save/restore and is
        // available when a workspace is saved as a launcher profile.
        if (!string.IsNullOrEmpty(adHocPassword))
            _secrets.Set(profile.Id, adHocPassword);
        // A profile can request its own dedicated workspace. Reuse an existing one
        // tied to the same profile, otherwise spin up a fresh workspace. Suppressed
        // while a workspace template is being rebuilt so its tabs stay together.
        if (!_suppressWorkspaceRouting && profile.WorkspaceLaunch == WorkspaceLaunch.NewWorkspace)
        {
            var existing = Workspaces.FirstOrDefault(w => w.SourceProfileId == profile.Id);
            if (existing is not null)
            {
                SelectWorkspace(existing);
            }
            else
            {
                // The workspace's display name: the profile's chosen name, or the
                // profile's own name when left blank — so several profiles that
                // recreate the same template each open under a distinct name.
                var name = string.IsNullOrWhiteSpace(profile.WorkspaceName) ? profile.Name : profile.WorkspaceName;
                var ws = new WorkspaceViewModel(this, Guid.NewGuid(), name) { SourceProfileId = profile.Id };
                Workspaces.Add(ws);
                SelectWorkspace(ws);

                // Which saved workspace to recreate as a launch *template*: the
                // profile's explicit template name, falling back to its workspace
                // name (older profiles stored the template there). Recreates the
                // template's tabs fresh in this new workspace, without re-saving it.
                // Many profiles can point at one "edge" template and each launch
                // builds its own copy. Mirrors the macOS app.
                var templateName = !string.IsNullOrWhiteSpace(profile.WorkspaceTemplateName)
                    ? profile.WorkspaceTemplateName
                    : profile.WorkspaceName;
                var template = string.IsNullOrWhiteSpace(templateName) ? null
                    : _store.WorkspaceTemplates.FirstOrDefault(
                        t => t.Name.Equals(templateName, StringComparison.OrdinalIgnoreCase));
                if (template is not null)
                {
                    if (!string.IsNullOrWhiteSpace(template.Color)) ws.Color = template.Color;
                    _suppressWorkspaceRouting = true;
                    _pendingPrimaryTabIndex = null;
                    try
                    {
                        if (template.Tabs.Count > 0)
                        {
                            // Re-point the template's ad-hoc tabs at this profile's own
                            // host so the whole recreated workspace follows this server.
                            var repoint = profile is { IsLocal: false } && !string.IsNullOrWhiteSpace(profile.Host)
                                ? profile.Host.Trim()
                                : null;
                            // Skip the template's own primary connection — this profile
                            // opens its ssh tab below, so it isn't duplicated.
                            RecreateTabs(template.Tabs, skipPrimaryConnection: true,
                                repointHost: string.IsNullOrEmpty(repoint) ? null : repoint,
                                launcher: profile);
                        }
                        else
                        {
                            foreach (var id in template.ProfileIds)
                            {
                                if (id == profile.Id) continue;   // the launcher opens its own tab below
                                if (_store.Profiles.FirstOrDefault(x => x.Id == id) is { } tp)
                                    OpenSession(tp);
                            }
                        }
                    }
                    finally { _suppressWorkspaceRouting = false; }
                    ApplyDrawerState(template);
                }
            }
        }

        string exe;
        string[] args;
        string? cwd = null;
        string? controlPath = null;

        if (profile.IsLocal)
        {
            exe = Environment.GetEnvironmentVariable("SHELL")
                  ?? (OperatingSystem.IsMacOS() ? "/bin/zsh" : "/bin/bash");
            args = new[] { "-l" };
            var start = SshCommandBuilder.ExpandPath(profile.StartPath.Trim());
            cwd = Directory.Exists(start) ? start : null;
        }
        else
        {
            if (profile.UseMosh)
            {
                exe = File.Exists("/opt/homebrew/bin/mosh") ? "/opt/homebrew/bin/mosh"
                    : File.Exists("/usr/local/bin/mosh") ? "/usr/local/bin/mosh"
                    : "mosh";
                args = SshCommandBuilder.MoshArguments(profile).ToArray();
            }
            else
            {
                // A ControlMaster socket lets us add/remove forwards live (ssh -O forward).
                controlPath = ControlSocketPath(profile.Id);
                exe = File.Exists("/usr/bin/ssh") ? "/usr/bin/ssh" : "ssh";
                args = SshCommandBuilder.Arguments(profile, controlPath).ToArray();
            }
        }

        var tab = new TerminalTabViewModel(
            // SSH tabs without a run-on-connect command are just labelled "SSH"; the
            // constructor overrides this with the command's program name when one is
            // set. Local shells keep their profile/ad-hoc name.
            title: profile.IsLocal ? profile.Name : "SSH",
            executable: exe,
            args: args,
            env: null,
            workingDirectory: cwd,
            runOnConnect: profile.IsLocal ? null : (runOnConnectOverride ?? profile.RunOnConnect),
            fontSize: fontOverride is { } fo && fo > 0 ? fo : profile.FontSize,
            theme: string.IsNullOrEmpty(themeOverride)
                ? TerminalTheme.ById(profile.Theme)
                : TerminalTheme.ById(themeOverride),
            snippets: profile.Snippets,
            autoPassword: profile.IsLocal ? null : (adHocPassword ?? _secrets.Get(profile.Id)));

        tab.ProfileId = profile.Id;
        tab.Profile = profile;
        tab.TabColor = profile.TabColor;
        tab.CloseRequested += CloseTab;
        tab.ControlSocketPath = controlPath;

        if (profile.LogSession)
        {
            var dir = Path.Combine(Path.GetDirectoryName(_store.StoragePath) ?? ".", "logs");
            var safe = string.Join("_", profile.Name.Split(Path.GetInvalidFileNameChars()));
            var stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
            tab.Terminal.StartLogging(Path.Combine(dir, $"{safe}-{stamp}.log"));
        }

        Tabs.Add(tab);
        SelectedTab = tab;

        // When this profile just recreated a saved-workspace template, restore its own
        // connection tab to the slot it occupied in the saved tab order (it was skipped
        // during recreation and appended here at the end). Nested launches while a
        // template is being rebuilt keep _suppressWorkspaceRouting set, so only the
        // outer launcher repositions.
        if (!_suppressWorkspaceRouting && _pendingPrimaryTabIndex is { } slot)
        {
            _pendingPrimaryTabIndex = null;
            var last = Tabs.Count - 1;
            if (slot >= 0 && slot < last)
            {
                Tabs.Move(last, slot);
                RecomputeDocks();
            }
        }
    }

    private void CloseTab(TabViewModel tab)
    {
        tab.CloseRequested -= CloseTab;
        RecordClosedTab(tab);
        var wsId = tab.WorkspaceId;
        var wasSelected = SelectedTab == tab;
        // Position of the closing tab among its workspace's tabs, so we can pick
        // its left neighbour (or the right one if it was leftmost) afterwards.
        var pos = Tabs.Where(t => t.WorkspaceId == wsId).ToList().IndexOf(tab);
        Tabs.Remove(tab);
        tab.Dispose();
        if (wasSelected)
        {
            var sameWs = Tabs.Where(t => t.WorkspaceId == wsId).ToList();
            SelectedTab = sameWs.Count == 0 ? null : sameWs[pos > 0 ? pos - 1 : 0];
        }
    }

    // ---- Broadcast input + scrollback ----

    /// <summary>When on, keystrokes typed in one terminal are mirrored to every
    /// other terminal in the same workspace (matches the macOS "broadcast" mode).</summary>
    [ObservableProperty] private bool _broadcastInput;

    private void OnTerminalUserInput(Views.Controls.TerminalControl source, byte[] data)
    {
        if (!BroadcastInput) return;
        var wsId = Tabs.OfType<TerminalTabViewModel>()
            .FirstOrDefault(t => ReferenceEquals(t.Terminal, source))?.WorkspaceId;
        if (wsId is null) return;
        foreach (var t in Tabs.OfType<TerminalTabViewModel>())
            if (t.WorkspaceId == wsId && !ReferenceEquals(t.Terminal, source))
                t.Terminal.MirrorInput(data);
    }

    [RelayCommand]
    private void ToggleBroadcast() => BroadcastInput = !BroadcastInput;

    /// <summary>Copy a terminal's full scrollback to the clipboard. Falls back to
    /// the selected tab when no tab is supplied (palette / keyboard).</summary>
    [RelayCommand]
    private void CopyTerminalScrollback(TabViewModel? tab = null)
    {
        if ((tab ?? SelectedTab) is TerminalTabViewModel t)
            CopyToClipboardRequested?.Invoke(t.Terminal.ScrollbackText());
    }

    /// <summary>Clear a terminal's scrollback and visible screen. Falls back to the
    /// selected tab when no tab is supplied.</summary>
    [RelayCommand]
    private void ClearTerminalScrollback(TabViewModel? tab = null)
    {
        if ((tab ?? SelectedTab) is TerminalTabViewModel t)
        {
            t.Terminal.Clear();
            StatusMessage = "Cleared terminal.";
        }
    }

    /// <summary>Save a terminal's full scrollback to a text file. Falls back to the
    /// selected tab when no tab is supplied.</summary>
    [RelayCommand]
    private async Task SaveTerminalScrollback(TabViewModel? tab = null)
    {
        if ((tab ?? SelectedTab) is not TerminalTabViewModel t) return;
        if (ExportFileRequested is null) return;
        var suggested = $"{t.Title.Replace('/', '-')}.log";
        var path = await ExportFileRequested.Invoke(suggested);
        if (string.IsNullOrEmpty(path)) return;
        try
        {
            await File.WriteAllTextAsync(path, t.Terminal.ScrollbackText());
            StatusMessage = "Saved terminal log.";
        }
        catch (Exception ex)
        {
            StatusMessage = "Couldn't save log: " + ex.Message;
        }
    }

    /// <summary>The currently selected terminal tab, if any (used by palette actions).</summary>
    private TerminalTabViewModel? ActiveTerminal => SelectedTab as TerminalTabViewModel;

    /// <summary>Disconnect every live terminal session across all workspaces.</summary>
    [RelayCommand]
    private void DisconnectAll()
    {
        var live = Tabs.OfType<TerminalTabViewModel>().Where(t => t.IsRunning).ToList();
        foreach (var t in live)
            t.DisconnectCommand.Execute(null);
        RecomputeConnections();
        SetStatus($"Disconnected {live.Count} session{(live.Count == 1 ? "" : "s")}.");
    }

    /// <summary>Insert snippet text into the active terminal (from the command palette).</summary>
    private void RunSnippetInActive(CommandSnippet snippet)
    {
        if (ActiveTerminal is { } t)
            t.InsertSnippetCommand.Execute(snippet);
        else
            SetStatus("Open a terminal first to run a snippet.");
    }

    /// <summary>Re-run a command from any terminal's history in the active terminal.</summary>
    private void RunHistoryInActive(string command)
    {
        if (ActiveTerminal is { } t)
            t.RunHistoryCommand.Execute(command);
        else
            SetStatus("Open a terminal first to run a command.");
    }

    // ---- Tunnel health + live port forwards ----

    private Avalonia.Threading.DispatcherTimer? _healthTimer;

    /// <summary>A short, unique ControlMaster socket path for a profile's tunnel,
    /// kept in the temp dir so it stays under the ~104-char unix-socket limit.</summary>
    private static string ControlSocketPath(Guid profileId)
        => Path.Combine(Path.GetTempPath(), $"rs-{profileId.ToString("N")[..8]}.sock");

    private void StartHealthMonitoring()
    {
        _healthTimer = new Avalonia.Threading.DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(5)
        };
        _healthTimer.Tick += (_, _) => _ = ProbeTunnelHealthAsync();
        _healthTimer.Start();
    }

    private async Task ProbeTunnelHealthAsync()
    {
        var running = Tabs.OfType<TerminalTabViewModel>()
            .Where(t => t is { ProfileId: not null, IsRunning: true })
            .Select(t => t.ProfileId!.Value)
            .ToHashSet();

        foreach (var section in SidebarSections)
            foreach (var row in section.Rows)
            {
                if (!running.Contains(row.Profile.Id)) { row.Health = TunnelHealth.Unknown; continue; }
                var endpoints = row.Profile.LocalForwardEndpoints.ToList();
                if (endpoints.Count == 0) { row.Health = TunnelHealth.Unknown; continue; }
                var healthy = await TcpProbe.AllReachableAsync(endpoints, TimeSpan.FromSeconds(2));
                row.Health = healthy ? TunnelHealth.Healthy : TunnelHealth.Degraded;
            }
    }

    /// <summary>Whether the selected profile has a running ssh tunnel with a live control socket.</summary>
    private TerminalTabViewModel? LiveTunnelFor(SshProfile profile) =>
        Tabs.OfType<TerminalTabViewModel>()
            .FirstOrDefault(t => t.ProfileId == profile.Id && t.IsRunning && t.ControlSocketPath != null);

    /// <summary>Add or cancel a forward on a live tunnel via <c>ssh -O forward|cancel</c>.</summary>
    private void RunControlForward(string op, PortForward forward, SshProfile profile, string socket)
    {
        if (SshCommandBuilder.ForwardOption(forward) is not { } option) return;
        var dest = SshCommandBuilder.Destination(profile);
        if (string.IsNullOrEmpty(dest)) return;
        var ssh = File.Exists("/usr/bin/ssh") ? "/usr/bin/ssh" : "ssh";
        var psi = new System.Diagnostics.ProcessStartInfo(ssh)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var a in new[] { "-S", socket, "-O", op, option.Flag, option.Spec, dest })
            psi.ArgumentList.Add(a);
        try { System.Diagnostics.Process.Start(psi); } catch { /* best-effort */ }
    }

    /// <summary>Live-add a forward to the selected profile's running tunnel (and persist it).</summary>
    public void AddLiveForward(PortForward forward, SshProfile profile, bool persist)
    {
        if (LiveTunnelFor(profile) is not { ControlSocketPath: { } socket }) return;
        RunControlForward("forward", forward, profile, socket);
        if (persist)
        {
            profile.Forwards.Add(forward);
            _store.Update(profile);
            ReloadProfiles();
        }
    }

    /// <summary>Live-cancel a forward on the selected profile's running tunnel (and un-persist it).</summary>
    public void CancelLiveForward(PortForward forward, SshProfile profile, bool persist)
    {
        if (LiveTunnelFor(profile) is not { ControlSocketPath: { } socket }) return;
        RunControlForward("cancel", forward, profile, socket);
        if (persist)
        {
            profile.Forwards.RemoveAll(f => f.Id == forward.Id);
            _store.Update(profile);
            ReloadProfiles();
        }
    }

    /// <summary>Re-open a forward on the selected profile's live tunnel (no persist change).</summary>
    [RelayCommand]
    private void StartForwardLive(PortForward? forward)
    {
        if (forward is null || SelectedProfile is not { } p) return;
        AddLiveForward(forward, p, persist: false);
        StatusMessage = $"Started forward {forward.Summary}";
    }

    /// <summary>Stop a forward on the selected profile's live tunnel (no persist change).</summary>
    [RelayCommand]
    private void StopForwardLive(PortForward? forward)
    {
        if (forward is null || SelectedProfile is not { } p) return;
        CancelLiveForward(forward, p, persist: false);
        StatusMessage = $"Stopped forward {forward.Summary}";
    }

    // ---- Detached (pop-out) terminal windows ----    /// <summary>Remembers each detached terminal's owning workspace so it can be re-attached.</summary>
    private readonly Dictionary<TerminalTabViewModel, Guid> _detached = new();

    /// <summary>Raised so the view can present a detached terminal in its own window.</summary>
    public event Action<TerminalTabViewModel>? DetachTerminalRequested;

    public bool IsDetachable(TabViewModel? tab) => tab is TerminalTabViewModel;

    /// <summary>Connect (reconnect) a disconnected remote terminal tab from its
    /// right-click menu.</summary>
    [RelayCommand]
    private void ConnectTab(TabViewModel? tab)
    {
        // Defer: Reconnect flips IsRunning, which toggles the Connect/Disconnect
        // menu items' IsVisible on the very context menu that's mid-dismissal.
        // Mutating it synchronously forces the closing popup to re-render while its
        // native surface is being torn down → a compositor present-surface crash on
        // macOS. Posting lets the popup fully close first.
        if (tab is TerminalTabViewModel term && !term.IsRunning)
            Avalonia.Threading.Dispatcher.UIThread.Post(
                () => term.ReconnectCommand.Execute(null),
                Avalonia.Threading.DispatcherPriority.Background);
    }

    /// <summary>Disconnect a live remote terminal tab (keeps the tab open) from its
    /// right-click menu.</summary>
    [RelayCommand]
    private void DisconnectTab(TabViewModel? tab)
    {
        // Deferred for the same reason as ConnectTab — see note above.
        if (tab is TerminalTabViewModel term && term.IsRunning)
            Avalonia.Threading.Dispatcher.UIThread.Post(
                () => term.DisconnectCommand.Execute(null),
                Avalonia.Threading.DispatcherPriority.Background);
    }

    /// <summary>Edit an ssh terminal tab's connection in place from its right-click
    /// menu — a lightweight host / port / user / run-on-connect sheet (not the full
    /// profile editor). Saving re-points and reconnects just this tab; the change is
    /// per-tab, so several tabs on one server can each carry a different command and
    /// the underlying saved profile is left untouched.</summary>
    [RelayCommand]
    private async Task EditTabConnection(TabViewModel? tab)
    {
        if (AdHocConnectionRequested is null) return;

        // MQTT / Redis explorer tabs re-point through the same lightweight sheet.
        if (tab is MqttTabViewModel mqtt)
        {
            var pf = new AdHocConnectionPrefill(mqtt.Host ?? "", mqtt.Port, mqtt.User ?? "", "", IsEdit: true);
            var res = await AdHocConnectionRequested(AdHocConnectionKind.Mqtt, pf);
            if (res is null) return;
            SetStatus($"Reconnecting {res.Host}…");
            await mqtt.ReconnectWith(res.Host, res.Port,
                string.IsNullOrEmpty(res.Username) ? null : res.Username,
                string.IsNullOrEmpty(res.Password) ? null : res.Password);
            return;
        }

        if (tab is RedisTabViewModel redis)
        {
            var pf = new AdHocConnectionPrefill(redis.Host ?? "", redis.Port, "", "", IsEdit: true);
            var res = await AdHocConnectionRequested(AdHocConnectionKind.Redis, pf);
            if (res is null) return;
            SetStatus($"Reconnecting {res.Host}…");
            await redis.ReconnectWith(res.Host, res.Port,
                string.IsNullOrEmpty(res.Password) ? null : res.Password);
            return;
        }

        if (tab is not TerminalTabViewModel term || term.Profile is not { IsLocal: false } p) return;

        var prefill = new AdHocConnectionPrefill(
            p.Host, int.TryParse(p.Port, out var pt) ? pt : 22, p.Username,
            term.RunOnConnect ?? "", IsEdit: true, Snippets: p.Snippets);
        var r = await AdHocConnectionRequested(AdHocConnectionKind.Ssh, prefill);
        if (r is null) return;

        var connChanged = r.Host != p.Host || r.Port.ToString() != p.Port || r.Username != p.Username;

        var updated = p.Clone();
        updated.Host = r.Host;
        updated.Port = r.Port.ToString();
        updated.Username = r.Username;
        updated.RunOnConnect = string.IsNullOrWhiteSpace(r.RunOnConnect) ? "" : r.RunOnConnect.Trim();
        // Apply the edited command snippets to the profile and, so the ❏ header
        // button reflects them immediately, to the live tab.
        if (r.Snippets is { } sn)
        {
            updated.Snippets = sn.Select(s => new CommandSnippet { Label = s.Label, Command = s.Command }).ToList();
            term.ReplaceSnippets(updated.Snippets);
        }
        // If the connection details changed on a *saved* profile, detach this tab
        // (fresh id) so the re-point stays per-tab and snapshots as an ad-hoc tab
        // rather than reverting to the saved profile's original host.
        if (connChanged && Profiles.Any(x => x.Id == p.Id))
            updated.Id = Guid.NewGuid();

        var controlPath = ControlSocketPath(updated.Id);
        var exe = File.Exists("/usr/bin/ssh") ? "/usr/bin/ssh" : "ssh";
        var args = SshCommandBuilder.Arguments(updated, controlPath).ToArray();

        term.Profile = updated;
        term.ProfileId = updated.Id;
        term.ControlSocketPath = controlPath;

        var runOnConnect = string.IsNullOrWhiteSpace(r.RunOnConnect) ? null : r.RunOnConnect.Trim();
        var pass = string.IsNullOrEmpty(r.Password) ? _secrets.Get(p.Id) : r.Password;
        // Keep the (possibly detached) tab's password in the secret store keyed by
        // its profile id, so a saved workspace remembers it.
        if (!string.IsNullOrEmpty(pass)) _secrets.Set(updated.Id, pass);
        term.Repoint(exe, args, null, null, runOnConnect, pass);
        SetStatus($"Reconnecting {r.Host}…");
    }

    /// <summary>Copy a terminal tab's host/IP to the clipboard.</summary>
    [RelayCommand]
    private void CopyTabHost(TabViewModel? tab)
    {
        if (tab?.Host is { } host && !string.IsNullOrWhiteSpace(host))
        {
            CopyToClipboardRequested?.Invoke(host);
            StatusMessage = $"Copied {host}";
        }
    }

    /// <summary>
    /// Move a terminal tab into its own floating window without disturbing its
    /// process or tunnels. Mirrors the macOS "Detach into New Window".
    /// </summary>
    [RelayCommand]
    private void DetachTab(TabViewModel? tab)
    {
        if (tab is not TerminalTabViewModel term || _detached.ContainsKey(term)) return;

        _detached[term] = term.WorkspaceId;
        var idx = Tabs.IndexOf(term);
        Tabs.Remove(term);
        if (SelectedTab == term)
        {
            var sameWs = Tabs.Where(t => t.WorkspaceId == term.WorkspaceId).ToList();
            SelectedTab = sameWs.Count > 0 ? sameWs[Math.Min(idx, sameWs.Count - 1)] : null;
        }
        DetachTerminalRequested?.Invoke(term);
    }

    /// <summary>Prompt for a custom tab name and apply it. An entered name overrides the
    /// tab's auto-generated title; clearing the field (blank + OK) reverts the tab to its
    /// normal naming convention. Cancelling leaves the tab untouched.</summary>
    [RelayCommand]
    private async Task RenameTab(TabViewModel? tab)
    {
        if (tab is null || WorkspaceNameRequested is null) return;
        var entered = await WorkspaceNameRequested("Rename tab", tab.DisplayTitle);
        if (entered is null) return; // cancelled
        tab.CustomTitle = entered.Trim();
    }

    private readonly UpdateService _updates = new();

    /// <summary>Manually check for a newer release from the Tools menu. Gives the user
    /// feedback whether an update is available, they're up to date, or (in a dev build)
    /// auto-update isn't active.</summary>
    [RelayCommand]
    private Task CheckForUpdates() => RunUpdateCheck(interactive: true);

    /// <summary>Shared update flow. When <paramref name="interactive"/> is false the check
    /// is silent unless an update is actually found; when true the user gets status
    /// feedback for every outcome.</summary>
    private async Task RunUpdateCheck(bool interactive)
    {
        if (!_updates.IsInstalled)
        {
            if (interactive)
                SetStatus("Auto-update is only available in the installed app.");
            return;
        }

        Velopack.UpdateInfo? info;
        try
        {
            info = await _updates.CheckAsync();
        }
        catch
        {
            if (interactive) SetStatus("Couldn't check for updates.");
            return;
        }

        if (info is null)
        {
            if (interactive) SetStatus("You’re running the latest version.");
            return;
        }

        var target = info.TargetFullRelease.Version.ToString();
        var confirm = await DialogService.ConfirmAsync(
            "Update available",
            $"Remote Stuff CP {target} is available (you have {_updates.CurrentVersion ?? "an older version"}). " +
            "Download and install it now? The app will restart to finish.",
            "Install & Restart", "Later");
        if (!confirm) return;

        SetStatus($"Downloading update {target}…");
        try
        {
            await _updates.DownloadAndApplyAsync(info); // relaunches the app on success
        }
        catch (Exception ex)
        {
            SetStatus("Update failed: " + ex.Message);
        }
    }

    /// <summary>Open a duplicate of <paramref name="tab"/> in the same workspace.
    /// Rebuilds from the tab's snapshot (same host/port/user/profile) and copies its
    /// dock position and accent colour. Tabs that can't be snapshotted are ignored.</summary>
    [RelayCommand]
    private void DuplicateTab(TabViewModel? tab)
    {
        if (tab is null) return;
        var snap = tab.CreateSnapshot();
        if (snap is null) return;

        var before = Tabs.Count;
        RecreateTab(snap);
        var newTabs = new List<TabViewModel>();
        for (var i = before; i < Tabs.Count; i++)
        {
            Tabs[i].WorkspaceId = tab.WorkspaceId;
            if (tab.Dock != DockSide.Center) Tabs[i].Dock = tab.Dock;
            if (!string.IsNullOrEmpty(tab.TabColor)) Tabs[i].TabColor = tab.TabColor;
            if (!string.IsNullOrEmpty(tab.CustomTitle)) Tabs[i].CustomTitle = tab.CustomTitle;
            newTabs.Add(Tabs[i]);
        }
        if (newTabs.Count > 0)
        {
            // Position the duplicate(s) immediately to the right of the source tab
            // instead of at the end of the strip.
            var insertAt = Tabs.IndexOf(tab) + 1;
            foreach (var nt in newTabs)
            {
                var from = Tabs.IndexOf(nt);
                if (from >= 0 && from != insertAt)
                    Tabs.Move(from, from < insertAt ? insertAt - 1 : insertAt);
                insertAt = Tabs.IndexOf(nt) + 1;
            }
            SelectedTab = newTabs[^1];
            RecomputeDocks();
        }
    }

    /// <summary>Bring a detached terminal back as a tab (called when its window closes).</summary>
    public void ReattachTab(TerminalTabViewModel term)
    {
        if (!_detached.TryGetValue(term, out var wsId)) return;
        _detached.Remove(term);
        term.WorkspaceId = wsId;
        // Only restore it if its workspace still exists; otherwise drop it home.
        if (Workspaces.All(w => w.Id != wsId) && CurrentWorkspace is { } ws)
            term.WorkspaceId = ws.Id;
        Tabs.Add(term);
        SelectedTab = term;
    }

    // ---- Workspaces ----

    public void SelectWorkspace(WorkspaceViewModel ws)    {
        if (CurrentWorkspace == ws) return;
        foreach (var w in Workspaces) w.IsCurrent = w == ws;
        CurrentWorkspace = ws;
        // Refresh the tab lists FIRST so the tab-strip ListBox already contains this
        // workspace's tabs before we set SelectedTab. Otherwise its TwoWay SelectedItem
        // binding sees a tab that isn't in its (still-previous) ItemsSource, rejects it,
        // and pushes null back — dropping us onto the welcome screen.
        RecomputeDocks();
        // Restore the tab that was active when this workspace was last current, falling
        // back to a sensible default (a center tab, else the first tab).
        var wsTabs = Tabs.Where(t => t.WorkspaceId == ws.Id).ToList();
        SelectedTab = wsTabs.FirstOrDefault(t => t.Id == ws.LastSelectedTabId)
                      ?? wsTabs.FirstOrDefault(t => t.Dock == DockSide.Center)
                      ?? wsTabs.FirstOrDefault();
    }

    [RelayCommand]
    private void NewWorkspace()
    {
        var ws = new WorkspaceViewModel(this, Guid.NewGuid(), $"Workspace {Workspaces.Count + 1}");
        Workspaces.Add(ws);
        SelectWorkspace(ws);
    }

    [RelayCommand]
    private void OpenSettings() => SettingsRequested?.Invoke(new SettingsViewModel(Settings));

    [RelayCommand]
    private void OpenDeveloperTools() =>
        DeveloperToolsRequested?.Invoke(new DeveloperViewModel(BuildDiagnosticsReport));

    [RelayCommand]
    private void CompareProfiles() =>
        CompareProfilesRequested?.Invoke(new ProfileComparisonViewModel(
            _store.Profiles,
            () => { _store.Save(); ReloadProfiles(); }));

    [RelayCommand]
    private void SyncProfilesGit() =>
        GitSyncRequested?.Invoke(new GitSyncViewModel(
            new GitProfileSync(_store.StoragePath),
            () => { _store.Reload(); ReloadProfiles(); }));

    /// <summary>Snapshot of runtime + app state for the Developer Tools popout.</summary>
    public string BuildDiagnosticsReport()
    {
        var proc = System.Diagnostics.Process.GetCurrentProcess();
        var sb = new System.Text.StringBuilder();

        sb.AppendLine("=== Runtime ===");
        sb.AppendLine($"App version   : {typeof(MainWindowViewModel).Assembly.GetName().Version}");
        sb.AppendLine($"OS            : {System.Runtime.InteropServices.RuntimeInformation.OSDescription}");
        sb.AppendLine($"Architecture  : {System.Runtime.InteropServices.RuntimeInformation.OSArchitecture}");
        sb.AppendLine($".NET          : {System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription}");
        sb.AppendLine($"Avalonia      : {typeof(Avalonia.Application).Assembly.GetName().Version}");
        sb.AppendLine($"Process ID    : {proc.Id}");
        sb.AppendLine($"Working set   : {proc.WorkingSet64 / (1024 * 1024)} MB");
        sb.AppendLine($"Managed heap  : {GC.GetTotalMemory(false) / (1024 * 1024)} MB");
        sb.AppendLine($"Threads       : {proc.Threads.Count}");
        sb.AppendLine($"Uptime        : {DateTime.Now - proc.StartTime:hh\\:mm\\:ss}");
        sb.AppendLine($"Settings file : {Settings.FilePath}");
        sb.AppendLine($"Generated     : {DateTime.Now:yyyy-MM-dd HH:mm:ss}");
        sb.AppendLine();

        sb.AppendLine($"=== Tabs ({Tabs.Count}) ===");
        foreach (var t in Tabs)
            sb.AppendLine($"  [{t.GetType().Name}] {t.Title}  glyph={t.Glyph}  ws={t.WorkspaceId}  running={t.IsRunning}");
        sb.AppendLine();

        sb.AppendLine($"=== Workspaces ({Workspaces.Count}) ===");
        foreach (var w in Workspaces)
            sb.AppendLine($"  {w.Name}  tabs={Tabs.Count(x => x.WorkspaceId == w.Id)}{(w == CurrentWorkspace ? "  (current)" : "")}");
        sb.AppendLine();

        sb.AppendLine($"=== Profiles ({Profiles.Count}) ===");
        foreach (var p in Profiles)
            sb.AppendLine($"  {p.Name}  {p.Username}@{p.Host}:{p.Port}");
        sb.AppendLine();

        sb.AppendLine("=== ZeroTier ===");
        sb.AppendLine($"  Networks      : {_zeroTier.Networks.Count}");
        sb.AppendLine();

        sb.AppendLine("=== Settings ===");
        sb.AppendLine($"  Theme                : {Settings.AppTheme}");
        sb.AppendLine($"  Font size            : {Settings.DefaultTerminalFontSize}");
        sb.AppendLine($"  ZeroTier online-only : {Settings.ZeroTierShowOnlineOnly}");
        sb.AppendLine($"  ZeroTier member-only : {Settings.ZeroTierShowMemberOfOnly}");

        return sb.ToString();
    }

    [RelayCommand]
    private void OpenKnownHosts() => KnownHostsRequested?.Invoke();

    [RelayCommand]
    private void OpenHelp() => HelpRequested?.Invoke();

    public void CloseWorkspace(WorkspaceViewModel ws)
    {
        // Close (and remember) every tab in the workspace first.
        foreach (var t in Tabs.Where(t => t.WorkspaceId == ws.Id).ToList())
        {
            t.CloseRequested -= CloseTab;
            RecordClosedTab(t);
            Tabs.Remove(t);
            t.Dispose();
        }
        var idx = Workspaces.IndexOf(ws);
        Workspaces.Remove(ws);
        // Never leave zero workspaces: closing the last one drops it and starts a
        // fresh, empty workspace so the welcome screen shows.
        if (Workspaces.Count == 0)
        {
            var fresh = new WorkspaceViewModel(this, Guid.NewGuid(), "Workspace 1");
            Workspaces.Add(fresh);
            SelectWorkspace(fresh);
            return;
        }
        if (CurrentWorkspace == ws)
            SelectWorkspace(Workspaces[Math.Min(idx, Workspaces.Count - 1)]);
    }

    /// <summary>Reorder <paramref name="moved"/> so it lands at <paramref name="target"/>'s
    /// position in the tab strip. Reorders the underlying <see cref="Tabs"/> list so the
    /// new order is captured by the session / workspace snapshot. Only reorders within a
    /// single workspace.</summary>
    public void MoveTab(TabViewModel moved, TabViewModel target)
    {
        if (moved == target || moved.WorkspaceId != target.WorkspaceId) return;
        var mi = Tabs.IndexOf(moved);
        var ti = Tabs.IndexOf(target);
        if (mi < 0 || ti < 0) return;
        Tabs.Move(mi, ti);
        SelectedTab = moved;
        RecomputeDocks();
        SaveLastSession();
    }

    [RelayCommand]
    private void CloseCurrentWorkspace()
    {
        if (CurrentWorkspace is { } ws) CloseWorkspace(ws);
    }

    [RelayCommand]
    private void NextWorkspace()
    {
        if (Workspaces.Count < 2 || CurrentWorkspace is not { } ws) return;
        var i = (Workspaces.IndexOf(ws) + 1) % Workspaces.Count;
        SelectWorkspace(Workspaces[i]);
    }

    [RelayCommand]
    private void PreviousWorkspace()
    {
        if (Workspaces.Count < 2 || CurrentWorkspace is not { } ws) return;
        var i = (Workspaces.IndexOf(ws) - 1 + Workspaces.Count) % Workspaces.Count;
        SelectWorkspace(Workspaces[i]);
    }

    /// <summary>Raised so the view can prompt for a workspace name (rename / save).</summary>
    public event Func<string, string, Task<string?>>? WorkspaceNameRequested;

    public async void BeginRenameWorkspace(WorkspaceViewModel ws)
    {
        if (WorkspaceNameRequested is null) return;
        var name = await WorkspaceNameRequested("Rename workspace", ws.Name);
        if (!string.IsNullOrWhiteSpace(name)) ws.Name = name.Trim();
    }

    public void SaveWorkspace(WorkspaceViewModel ws)
    {
        var template = new WorkspaceTemplate
        {
            Name = ws.Name,
            Color = ws.Color,
            Tabs = SnapshotTabs(ws)
        };
        CaptureDrawerState(template);
        _store.SaveWorkspaceTemplate(template);
        ws.IsSaved = true;
        RefreshSavedWorkspaces();
        SetStatus($"Saved workspace “{ws.Name}”.");
    }

    /// <summary>Save the current workspace's tabs as a named saved workspace — the
    /// "Save as Workspace…" counterpart to the in-place <see cref="SaveWorkspace"/>.
    /// Prompts for a name (so the workspace can be stored under a new one) and asks
    /// to confirm before overwriting an existing saved workspace, mirroring the Mac app.</summary>
    public async void SaveWorkspaceAs(WorkspaceViewModel ws)
    {
        if (WorkspaceNameRequested is null) return;
        var entered = await WorkspaceNameRequested("Save as Workspace", ws.Name);
        if (string.IsNullOrWhiteSpace(entered)) return;
        var name = entered.Trim();

        if (_store.WorkspaceTemplates.Any(t => t.Name.Equals(name, StringComparison.OrdinalIgnoreCase)))
        {
            var replace = await RemoteStuff.Services.DialogService.ConfirmAsync(
                "Replace Saved Workspace?",
                $"A saved workspace named “{name}” already exists. Replacing it overwrites its saved tabs with the current ones.",
                "Replace", "Cancel");
            if (!replace) return;
        }

        var template = new WorkspaceTemplate
        {
            Name = name,
            Color = ws.Color,
            Tabs = SnapshotTabs(ws)
        };
        CaptureDrawerState(template);
        _store.SaveWorkspaceTemplate(template);

        ws.Name = name;
        ws.IsSaved = true;
        RefreshSavedWorkspaces();
        SetStatus($"Saved workspace “{name}”.");
    }

    /// <summary>Snapshot every recreatable tab in a workspace, in tab order, tagging
    /// each with the edge it was docked to. Document and singleton tabs (editors,
    /// spreadsheets, the ZeroTier panel) return null from <c>CreateSnapshot</c> and
    /// are skipped.</summary>
    private List<TabSnapshot> SnapshotTabs(WorkspaceViewModel ws)
    {
        var result = new List<TabSnapshot>();
        foreach (var t in Tabs.Where(t => t.WorkspaceId == ws.Id))
        {
            var snap = t.CreateSnapshot();
            if (snap is null) continue;
            snap.Dock = t.Dock;
            snap.TabColor = t.TabColor;
            snap.CustomTitle = t.CustomTitle;
            // Persist ad-hoc tab credentials in the encrypted secret store, keyed by
            // the snapshot's stable id, so the workspace remembers them without
            // writing any plaintext password into the workspace JSON.
            switch (t)
            {
                case MqttTabViewModel m when !string.IsNullOrEmpty(m.ConnectionPassword):
                    _secrets.Set(snap.Id, m.ConnectionPassword);
                    break;
                case RedisTabViewModel r when !string.IsNullOrEmpty(r.ConnectionPassword):
                    _secrets.Set(snap.Id, r.ConnectionPassword);
                    break;
            }
            result.Add(snap);
        }
        return result;
    }

    /// <summary>Copy the current drawer collapse / size state into a template.</summary>
    private void CaptureDrawerState(WorkspaceTemplate t)
    {
        t.LeftCollapsed = _leftCollapsed;
        t.RightCollapsed = _rightCollapsed;
        t.TopCollapsed = _topCollapsed;
        t.BottomCollapsed = _bottomCollapsed;
        t.LeftWidth = _leftW;
        t.RightWidth = _rightW;
        t.TopHeight = _topH;
        t.BottomHeight = _bottomH;
    }

    /// <summary>Restore drawer collapse / size state from a template, then refresh.</summary>
    private void ApplyDrawerState(WorkspaceTemplate t)
    {
        _leftCollapsed = t.LeftCollapsed;
        _rightCollapsed = t.RightCollapsed;
        _topCollapsed = t.TopCollapsed;
        _bottomCollapsed = t.BottomCollapsed;
        if (t.LeftWidth > CollapsedSize) _leftW = t.LeftWidth;
        if (t.RightWidth > CollapsedSize) _rightW = t.RightWidth;
        if (t.TopHeight > CollapsedSize) _topH = t.TopHeight;
        if (t.BottomHeight > CollapsedSize) _bottomH = t.BottomHeight;
        RecomputeDocks();
        // Prefer a center tab as the active one now that docked tabs are in place.
        if (CurrentWorkspace is { } ws)
        {
            var wsTabs = Tabs.Where(x => x.WorkspaceId == ws.Id).ToList();
            SelectedTab = wsTabs.FirstOrDefault(x => x.Dock == DockSide.Center) ?? wsTabs.FirstOrDefault();
        }
    }

    /// <summary>Recreate a set of snapshotted tabs into the current workspace,
    /// restoring each tab's dock edge. When <paramref name="skipPrimaryConnection"/>
    /// is set (a profile launching a workspace template), the first ssh/local tab is
    /// skipped because the launching profile opens its own primary connection.
    /// When <paramref name="repointHost"/> is set (a "save workspace as profile"
    /// launcher opening its template), every ad-hoc connection tab is re-pointed at
    /// that host so the whole workspace follows the launching profile's server.
    /// When <paramref name="launcher"/> is set, MQTT / Redis tabs take their host and
    /// credentials from that profile's matching service forward.</summary>
    private void RecreateTabs(IEnumerable<TabSnapshot> snaps, bool skipPrimaryConnection,
        string? repointHost = null, SshProfile? launcher = null)
    {
        var skipped = false;
        foreach (var snap in snaps)
        {
            if (skipPrimaryConnection && !skipped &&
                (snap.Kind == "ssh" || snap.Kind == "local"))
            {
                skipped = true;
                // Remember where the primary connection sat in the saved tab order so
                // the launcher's own ssh tab (added at the end of OpenSession) can be
                // moved back into this slot, preserving the user's tab arrangement.
                _pendingPrimaryTabIndex = Tabs.Count;
                continue;
            }
            var before = Tabs.Count;
            RecreateTab(snap, repointHost, launcher);
            // Re-dock and re-colour whatever tab(s) this created from the saved snapshot.
            for (var i = before; i < Tabs.Count; i++)
            {
                if (snap.Dock != DockSide.Center) Tabs[i].Dock = snap.Dock;
                if (!string.IsNullOrEmpty(snap.TabColor)) Tabs[i].TabColor = snap.TabColor!;
                if (!string.IsNullOrEmpty(snap.CustomTitle)) Tabs[i].CustomTitle = snap.CustomTitle!;
            }
        }
    }

    /// <summary>Recreate a single tab from its snapshot. Profile-backed tabs prefer a
    /// matching saved profile; otherwise an ad-hoc tab is rebuilt from host/port/user
    /// (passwords aren't stored, so the user re-enters them — same as the macOS app).
    /// When <paramref name="repointHost"/> is set, ad-hoc tabs (and browser URLs) are
    /// re-pointed at that host. When <paramref name="launcher"/> is set, MQTT / Redis
    /// tabs take their host, port and credentials from that profile's matching service
    /// forward (mirroring how the macOS app opens a profile's service tabs).</summary>
    private void RecreateTab(TabSnapshot snap, string? repointHost = null, SshProfile? launcher = null)
    {
        SshProfile? Stored() =>
            snap.ProfileId is { } pid ? _store.Profiles.FirstOrDefault(x => x.Id == pid) : null;

        // Ad-hoc tabs follow the launching profile's host when re-pointing.
        string Repointed(string? host) =>
            string.IsNullOrEmpty(repointHost) ? (host ?? "") : repointHost!;

        switch (snap.Kind)
        {
            case "ssh":
            case "local":
            {
                var p = Stored()
                        ?? (snap.Kind == "local"
                            ? new SshProfile { IsLocal = true, Name = snap.Title ?? "Local" }
                            : AdHocProfile(Repointed(snap.Host), snap.Port <= 0 ? 22 : snap.Port, snap.Username ?? "",
                                           snap.ProfileId));
                OpenSession(p, runOnConnectOverride: snap.RunOnConnect,
                    themeOverride: snap.ThemeId, fontOverride: snap.FontSize);
                break;
            }
            case "sftp":
            {
                if (Stored() is { IsLocal: false } p) OpenSftpTab(p);
                // Reuse the original profile id so the saved SFTP password (kept in the
                // encrypted secret store, keyed by that id) is found on restore — and so
                // the "save password" path stays wired up instead of being disabled.
                else OpenSftpTab(AdHocProfile(Repointed(snap.Host), snap.Port <= 0 ? 22 : snap.Port, snap.Username ?? "",
                                              snap.ProfileId));
                break;
            }
            case "vnc-tunnel":
            {
                if (Stored() is { IsLocal: false } p) OpenVncTab(p, snap.Port <= 0 ? 5900 : snap.Port);
                else OpenVncDirectTab(Repointed(snap.Host), snap.Port <= 0 ? 5900 : snap.Port, Repointed(snap.Host));
                break;
            }
            case "vnc":
                OpenVncDirectTab(Repointed(snap.Host), snap.Port <= 0 ? 5900 : snap.Port, Repointed(snap.Host));
                break;
            case "browser":
                NewBrowserAt(RepointUrl(
                    string.IsNullOrWhiteSpace(snap.Url) ? "https://duckduckgo.com" : snap.Url!, repointHost));
                break;
            case "finder":
                OpenFinderAt(snap.Path);
                break;
            case "mqtt":
            {
                var host = Repointed(snap.Host);
                var (user, pass, port) = ServiceConnection(launcher, ForwardCategory.Mqtt, snap, 1883);
                OpenMqttTab(host, port, string.IsNullOrEmpty(user) ? null : user, pass,
                            host.Length == 0 ? "MQTT" : host, snap.Id);
                break;
            }
            case "redis":
            {
                var (_, rpass, rport) = ServiceConnection(launcher, ForwardCategory.Redis, snap, 6379);
                var rhost = Repointed(snap.Host);
                OpenRedisTab(rhost, rport, rpass, rhost.Length == 0 ? "Redis" : rhost, snap.Id);
                break;
            }
            case "network":
                NewNetworkCommand.Execute(null);
                break;
            case "mikrotik":
                NewMikroTikCommand.Execute(null);
                break;
        }
    }

    /// <summary>Resolve the host-independent connection details (username, password,
    /// port) for an MQTT / Redis tab being recreated. When a launching profile carries
    /// a matching service forward, its stored credentials win — the service username
    /// from the forward and the password from the encrypted secret store (keyed by the
    /// forward's id), connecting on the forward's target port — exactly how the macOS
    /// app opens a profile's service tabs. Otherwise the tab's own ad-hoc snapshot
    /// credentials are used.</summary>
    private (string User, string? Password, int Port) ServiceConnection(
        SshProfile? launcher, ForwardCategory category, TabSnapshot snap, int defaultPort)
    {
        if (launcher is not null)
        {
            var fwd = launcher.Forwards.FirstOrDefault(f => f.Category == category);
            if (fwd is not null)
            {
                var port = int.TryParse(fwd.TargetPort, out var tp) && tp > 0 ? tp : defaultPort;
                return (fwd.ServiceUsername ?? "", _secrets.Get(fwd.Id), port);
            }
        }
        return (snap.Username ?? "", _secrets.Get(snap.Id), snap.Port <= 0 ? defaultPort : snap.Port);
    }

    /// <summary>Swap the host of a browser URL for <paramref name="newHost"/> when a
    /// workspace is re-pointed at a launcher profile's server, leaving scheme, port
    /// and path intact. Returns the URL unchanged when there's nothing to re-point.</summary>
    private static string RepointUrl(string url, string? newHost)
    {
        if (string.IsNullOrEmpty(newHost)) return url;
        var candidate = url.Contains("://", StringComparison.Ordinal) ? url : "http://" + url;
        if (!Uri.TryCreate(candidate, UriKind.Absolute, out var uri)) return url;
        var builder = new UriBuilder(uri) { Host = newHost };
        return builder.Uri.ToString();
    }

    /// <summary>The workspace's primary remote connection: the profile that launched
    /// it, else the first profile-backed tab's profile.</summary>
    private SshProfile? WorkspacePrimaryProfile(WorkspaceViewModel ws)
    {
        if (ws.SourceProfileId is { } id &&
            _store.Profiles.FirstOrDefault(p => p.Id == id) is { } launcher)
            return launcher;

        var tab = Tabs.FirstOrDefault(t => t.WorkspaceId == ws.Id && t.ProfileId is not null);
        return tab?.ProfileId is { } pid
            ? _store.Profiles.FirstOrDefault(p => p.Id == pid)
            : null;
    }

    /// <summary>Turn a workspace into a one-click launcher profile in the sidebar.
    /// Clones the workspace's primary SSH connection into a new profile that opens
    /// its own dedicated workspace, so re-connecting reopens the workspace and any
    /// terminal / SFTP / VNC tabs added there all share that one connection.</summary>
    public async void SaveWorkspaceAsProfile(WorkspaceViewModel ws)
    {
        if (WorkspaceNameRequested is null) return;
        var entered = await WorkspaceNameRequested("Save workspace as profile", ws.Name);
        if (string.IsNullOrWhiteSpace(entered)) return;
        var name = entered.Trim();

        var source = WorkspacePrimaryProfile(ws);

        // Clone the primary connection so the launcher reconnects to the same
        // host / port / user; fall back to a local launcher when there's no
        // remote tab to seed from.
        var profile = source is { IsLocal: false } ? source.Clone() : new SshProfile { IsLocal = true };

        profile.Id = Guid.NewGuid();
        profile.Name = _store.UniqueName(name);
        profile.WorkspaceLaunch = WorkspaceLaunch.NewWorkspace;
        profile.WorkspaceName = name;
        profile.WorkspaceTemplateName = name;
        profile.IsWorkspaceLauncher = true;
        profile.IsFavorite = false;
        profile.AutoConnectOnLaunch = false;

        // Carry the saved password across so the launcher can authenticate.
        if (source is not null && _secrets.Get(source.Id) is { } pw && !string.IsNullOrEmpty(pw))
            _secrets.Set(profile.Id, pw);

        _store.Add(profile);
        ReloadProfiles();
        SelectedProfile = Profiles.FirstOrDefault(p => p.Id == profile.Id);

        // Save the workspace's tab layout as a template under the same name so
        // relaunching the profile rebuilds every tab (ssh, sftp, browser…) — with
        // its ad-hoc tabs re-pointed at this profile's host.
        var template = new WorkspaceTemplate
        {
            Name = name,
            Color = ws.Color,
            Tabs = SnapshotTabs(ws)
        };
        CaptureDrawerState(template);
        _store.SaveWorkspaceTemplate(template);
        RefreshSavedWorkspaces();

        // Bind this workspace to the new launcher so its New menu offers the same
        // server and re-connecting reuses this workspace.
        ws.SourceProfileId = profile.Id;
        ws.IsSaved = true;
        RecomputeDocks();
        SetStatus($"Saved “{profile.Name}” as a launcher profile.");
    }

    /// <summary>Open a saved workspace template as a new workspace, recreating every
    /// saved tab (ssh, sftp, vnc, browser, finder…). Falls back to the legacy
    /// profile-ids list for workspaces saved before full snapshots existed.</summary>
    public void OpenWorkspaceTemplate(WorkspaceTemplate template)
    {
        var ws = new WorkspaceViewModel(this, Guid.NewGuid(), template.Name) { IsSaved = true };
        if (!string.IsNullOrWhiteSpace(template.Color)) ws.Color = template.Color;
        Workspaces.Add(ws);
        SelectWorkspace(ws);
        _suppressWorkspaceRouting = true;
        try
        {
            if (template.Tabs.Count > 0)
            {
                RecreateTabs(template.Tabs, skipPrimaryConnection: false);
            }
            else
            {
                foreach (var id in template.ProfileIds)
                {
                    var p = _store.Profiles.FirstOrDefault(x => x.Id == id);
                    if (p != null) OpenSession(p);
                }
            }
        }
        finally { _suppressWorkspaceRouting = false; }
        ApplyDrawerState(template);
    }

    // ---- Workspace menu commands (operate on the current workspace) ----

    [RelayCommand]
    private void SaveCurrentWorkspace()
    {
        if (CurrentWorkspace is { } ws) SaveWorkspace(ws);
    }

    [RelayCommand]
    private void SaveCurrentWorkspaceAs()
    {
        if (CurrentWorkspace is { } ws) SaveWorkspaceAs(ws);
    }

    [RelayCommand]
    private void SaveCurrentWorkspaceAsProfile()
    {
        if (CurrentWorkspace is { } ws) SaveWorkspaceAsProfile(ws);
    }

    [RelayCommand]
    private void RenameCurrentWorkspace()
    {
        if (CurrentWorkspace is { } ws) BeginRenameWorkspace(ws);
    }

    private void DeleteSavedWorkspaceTemplate(WorkspaceTemplate template)
    {
        _store.DeleteWorkspaceTemplate(template.Name);
        RefreshSavedWorkspaces();
        SetStatus($"Deleted saved workspace “{template.Name}”.");
    }

    // ---- Startup: resume last session + auto-connect ----

    /// <summary>Called once after the window is shown to restore state and auto-connect.</summary>
    public void RunStartupTasks()
    {
        StartHealthMonitoring();

        if (Settings.ResumeLastSession)
            RestoreLastSession();

        RestoreEditorBackups();

        // Silently check GitHub for a newer release shortly after launch.
        if (Settings.AutoCheckUpdates)
            Avalonia.Threading.DispatcherTimer.RunOnce(
                () => _ = RunUpdateCheck(interactive: false), TimeSpan.FromSeconds(3));

        // Stagger auto-connect profiles so we don't spawn every ssh at once.
        var autos = _store.Profiles.Where(p => p.AutoConnectOnLaunch).ToList();
        var delay = 0;
        foreach (var p in autos)
        {
            var profile = p;
            Avalonia.Threading.DispatcherTimer.RunOnce(() => OpenSession(profile),
                TimeSpan.FromMilliseconds(delay));
            delay += 400;
        }
    }

    /// <summary>Reopen editor tabs for any unsaved buffers left behind by a crash.</summary>
    private void RestoreEditorBackups()
    {
        foreach (var b in EditorBackupStore.LoadAll())
        {
            var editor = EditorTabViewModel.FromBackup(b);
            editor.CloseRequested += CloseTab;
            Tabs.Add(editor);
            SelectedTab = editor;
        }
    }

    /// <summary>Repopulate every editor's "Compare ▾" flyout with the other open
    /// editors, so the user can diff any two buffers side by side.</summary>
    private void RefreshEditorCompareTargets()
    {
        var editors = Tabs.OfType<EditorTabViewModel>().ToList();
        foreach (var e in editors)
        {
            e.CompareTargets.Clear();
            foreach (var other in editors)
            {
                if (ReferenceEquals(other, e)) continue;
                var left = e;
                var right = other;
                e.CompareTargets.Add(new CompareTarget(right.Title, () => OpenDiff(left, right)));
            }
            e.NotifyCompareTargetsChanged();
        }
    }

    /// <summary>Open a read-only side-by-side comparison of two editor buffers.</summary>
    private void OpenDiff(EditorTabViewModel left, EditorTabViewModel right)
    {
        var diff = new DiffTabViewModel(left.Title, left.Text, right.Title, right.Text);
        diff.CloseRequested += CloseTab;
        if (CurrentWorkspace is { } ws) diff.WorkspaceId = ws.Id;
        Tabs.Add(diff);
        SelectedTab = diff;
    }

    private void RestoreLastSession()
    {
        var snapshot = _store.LoadLastSession();
        if (snapshot is null || snapshot.Workspaces.Count == 0) return;

        var firstWs = true;
        foreach (var w in snapshot.Workspaces)
        {
            WorkspaceViewModel ws;
            if (firstWs && CurrentWorkspace is { } cur && Tabs.All(t => t.WorkspaceId != cur.Id))
            {
                ws = cur;
                ws.Name = string.IsNullOrWhiteSpace(w.Name) ? ws.Name : w.Name;
            }
            else
            {
                ws = new WorkspaceViewModel(this, Guid.NewGuid(),
                    string.IsNullOrWhiteSpace(w.Name) ? $"Workspace {Workspaces.Count + 1}" : w.Name);
                Workspaces.Add(ws);
            }
            if (!string.IsNullOrWhiteSpace(w.Color)) ws.Color = w.Color;
            firstWs = false;

            SelectWorkspace(ws);
            _suppressWorkspaceRouting = true;
            try
            {
                if (w.Tabs.Count > 0)
                {
                    RecreateTabs(w.Tabs, skipPrimaryConnection: false);
                }
                else
                {
                    foreach (var id in w.ProfileIds)
                    {
                        var p = _store.Profiles.FirstOrDefault(x => x.Id == id);
                        if (p != null) OpenSession(p);
                    }
                }
            }
            finally { _suppressWorkspaceRouting = false; }
            ApplyDrawerState(w);
        }
        if (Workspaces.Count > 0)
        {
            SelectWorkspace(Workspaces[0]);
            ApplyDrawerState(snapshot.Workspaces[0]);
        }
    }

    /// <summary>Snapshot the current open tabs so they can be resumed next launch.
    /// Captures every recreatable tab kind, not just profile-backed connections.</summary>
    public void SaveLastSession()
    {
        var snapshot = new SessionSnapshot();
        foreach (var ws in Workspaces)
        {
            var tabs = SnapshotTabs(ws);
            if (tabs.Count == 0) continue;
            var t = new WorkspaceTemplate { Name = ws.Name, Color = ws.Color, Tabs = tabs };
            CaptureDrawerState(t);
            snapshot.Workspaces.Add(t);
        }
        _store.SaveLastSession(snapshot);
    }

    // ---- Recently closed (reopen closed tabs) ----

    /// <summary>Most-recently-closed tabs, newest first (capped).</summary>
    public ObservableCollection<ClosedItem> RecentlyClosed { get; } = new();
    public bool HasRecentlyClosed => RecentlyClosed.Count > 0;

    private void RecordClosedTab(TabViewModel tab)
    {
        Action? reopen = tab switch
        {
            _ when tab.ProfileId is { } pid && _store.Profiles.FirstOrDefault(p => p.Id == pid) is { } p
                => () => OpenSession(p),
            BrowserTabViewModel b => () => NewBrowserAt(b.InitialUrl),
            _ => null
        };
        if (reopen is null) return;

        RecentlyClosed.Insert(0, new ClosedItem(tab.Title, tab.Glyph, reopen));
        while (RecentlyClosed.Count > 12)
            RecentlyClosed.RemoveAt(RecentlyClosed.Count - 1);
        OnPropertyChanged(nameof(HasRecentlyClosed));
    }

    [RelayCommand]
    private void ReopenClosed(ClosedItem? item)
    {
        item ??= RecentlyClosed.FirstOrDefault();
        if (item is null) return;
        RecentlyClosed.Remove(item);
        OnPropertyChanged(nameof(HasRecentlyClosed));
        item.Reopen();
    }

    [RelayCommand(CanExecute = nameof(CanOpenSftp))]
    private void OpenSftp()
    {
        if (SelectedProfile is { IsLocal: false } p)
            OpenSftpTab(p);
    }

    private bool CanOpenSftp() => SelectedProfile is { IsLocal: false };

    public void OpenSftpTab(SshProfile profile, string? adHocPassword = null, bool adHoc = false)
    {
        var tab = new SftpTabViewModel(
            profile,
            adHocPassword ?? _secrets.Get(profile.Id),
            // Ad-hoc tabs use a throwaway profile that's never saved, so there's
            // nothing to persist a password into — don't offer to save it.
            passwordSaver: (profile.IsLocal || adHoc) ? null : pw => _secrets.Set(profile.Id, pw));
        tab.EditRequested += (name, content, saver) =>
        {
            var editor = new EditorTabViewModel(name, content, remoteSaver: saver);
            editor.CloseRequested += CloseTab;
            Tabs.Add(editor);
            SelectedTab = editor;
        };
        tab.CloseRequested += CloseTab;
        Tabs.Add(tab);
        SelectedTab = tab;
    }

    [RelayCommand]
    private void NewEditor()
    {
        var editor = new EditorTabViewModel("Untitled");
        editor.CloseRequested += CloseTab;
        Tabs.Add(editor);
        SelectedTab = editor;
    }

    // ---- "New" menu: add ad-hoc tabs to the current workspace ----

    /// <summary>The profile that launched the current workspace, if any.</summary>
    private SshProfile? CurrentWorkspaceProfile =>
        CurrentWorkspace?.SourceProfileId is { } id
            ? _store.Profiles.FirstOrDefault(p => p.Id == id)
            : null;

    /// <summary>True when the current workspace was launched from a (non-local)
    /// profile, so the New menu can offer quick "same server" actions.</summary>
    public bool HasWorkspaceServer => CurrentWorkspaceProfile is { IsLocal: false };

    /// <summary>Name of the current workspace's server (for New-menu labels).</summary>
    public string WorkspaceServerName => CurrentWorkspaceProfile?.Name ?? "";

    public string NewTerminalHereLabel => $"New Terminal — {WorkspaceServerName}";
    public string NewSftpHereLabel => $"New SFTP — {WorkspaceServerName}";
    public string NewVncHereLabel => $"New VNC — {WorkspaceServerName}";

    /// <summary>Open another SSH terminal to this workspace's server.</summary>
    [RelayCommand]
    private void NewTerminalHere()
    {
        if (CurrentWorkspaceProfile is { } p) OpenSession(p);
    }

    /// <summary>Open an SFTP tab to this workspace's server.</summary>
    [RelayCommand]
    private void NewSftpHere()
    {
        if (CurrentWorkspaceProfile is { IsLocal: false } p) OpenSftpTab(p);
    }

    /// <summary>Open a VNC console to this workspace's server.</summary>
    [RelayCommand]
    private void NewVncHere()
    {
        if (CurrentWorkspaceProfile is { IsLocal: false } p) OpenVncTab(p);
    }

    /// <summary>Per-profile entries for the New ▸ Terminal/SFTP/VNC submenus.</summary>
    public ObservableCollection<ProfileMenuItem> ConnectMenuItems { get; } = new();
    public ObservableCollection<ProfileMenuItem> SftpMenuItems { get; } = new();
    public ObservableCollection<ProfileMenuItem> VncMenuItems { get; } = new();

    private void RebuildProfileMenus()
    {
        ConnectMenuItems.Clear();
        SftpMenuItems.Clear();
        VncMenuItems.Clear();
        foreach (var p in Profiles)
        {
            var prof = p;
            ConnectMenuItems.Add(new ProfileMenuItem(prof.Name, () => OpenSession(prof)));
            if (!prof.IsLocal)
            {
                SftpMenuItems.Add(new ProfileMenuItem(prof.Name, () => OpenSftpTab(prof)));
                VncMenuItems.Add(new ProfileMenuItem(prof.Name, () => OpenVncTab(prof)));
            }
        }
        OnPropertyChanged(nameof(HasProfiles));
    }

    [RelayCommand]
    private void NewFinder() => OpenFinderAt(null);

    /// <summary>Open a local file-browser (Finder) tab at a given directory (null = home).</summary>
    public void OpenFinderAt(string? startPath)
    {
        var finder = new FinderTabViewModel(startPath);
        finder.EditRequested += (name, content, saver) =>
        {
            var editor = new EditorTabViewModel(name, content, remoteSaver: saver);
            editor.CloseRequested += CloseTab;
            Tabs.Add(editor);
            SelectedTab = editor;
        };
        finder.CloseRequested += CloseTab;
        Tabs.Add(finder);
        SelectedTab = finder;
    }

    [RelayCommand]
    private void NewBrowser()
    {
        var browser = new BrowserTabViewModel("https://duckduckgo.com");
        browser.CloseRequested += CloseTab;
        Tabs.Add(browser);
        SelectedTab = browser;
    }

    private void NewBrowserAt(string url)
    {
        var browser = new BrowserTabViewModel(url);
        browser.CloseRequested += CloseTab;
        Tabs.Add(browser);
        SelectedTab = browser;
    }

    [RelayCommand]
    private void NewSpreadsheet()
    {
        var sheet = new SpreadsheetTabViewModel();
        sheet.CloseRequested += CloseTab;
        Tabs.Add(sheet);
        SelectedTab = sheet;
    }

    /// <summary>Open a spreadsheet tab for an existing CSV/TSV/XLSX file.</summary>
    public void OpenSpreadsheetTab(string path)
    {
        var sheet = new SpreadsheetTabViewModel(path);
        sheet.CloseRequested += CloseTab;
        Tabs.Add(sheet);
        SelectedTab = sheet;
    }

    [RelayCommand]
    private void NewNetwork()
    {
        var existing = Tabs.OfType<NetworkTabViewModel>().FirstOrDefault();
        if (existing is not null) { SelectedTab = existing; return; }
        var net = new NetworkTabViewModel();
        net.CloseRequested += CloseTab;
        Tabs.Add(net);
        SelectedTab = net;
    }

    [RelayCommand]
    private void NewMikroTik()
    {
        var mt = new MikroTikTabViewModel();
        mt.CloseRequested += CloseTab;
        Tabs.Add(mt);
        SelectedTab = mt;
    }

    // ---- Service launchers (MQTT / Redis / web) ----

    public void OpenMqttTab(string host, int port, string? user, string? pass, string title, Guid? id = null)
    {
        var tab = new MqttTabViewModel(host, port, user, pass, title, id);
        tab.CloseRequested += CloseTab;
        Tabs.Add(tab);
        SelectedTab = tab;
    }

    public void OpenRedisTab(string host, int port, string? password, string title, Guid? id = null)
    {
        var tab = new RedisTabViewModel(host, port, password, title, id);
        tab.CloseRequested += CloseTab;
        Tabs.Add(tab);
        SelectedTab = tab;
    }

    /// <summary>Open a tunneled VNC console for a profile (ssh -N -L to the remote VNC port).</summary>
    public void OpenVncTab(SshProfile profile, int remoteVncPort = 5900)
    {
        var tab = new VncTabViewModel(profile, remoteVncPort);
        tab.CloseRequested += CloseTab;
        Tabs.Add(tab);
        SelectedTab = tab;
    }

    /// <summary>Open a direct (ad-hoc) VNC console to a host:port with no SSH tunnel.</summary>
    public void OpenVncDirectTab(string host, int port, string title)
    {
        var tab = new VncTabViewModel(host, port, title);
        tab.CloseRequested += CloseTab;
        Tabs.Add(tab);
        SelectedTab = tab;
    }

    /// <summary>Open the VNC console for the selected sidebar row (via its SSH tunnel).</summary>
    public void VncRow(ProfileRowViewModel row)
    {
        if (!row.Profile.IsLocal)
            OpenVncTab(row.Profile);
    }

    private bool CanOpenVnc() => SelectedProfile is { IsLocal: false };

    [RelayCommand(CanExecute = nameof(CanOpenVnc))]
    private void OpenVnc()
    {
        if (SelectedProfile is { IsLocal: false } p)
            OpenVncTab(p);
    }

    /// <summary>Prompt for a host/port and open a direct VNC console (ad-hoc).</summary>
    [RelayCommand]
    private async Task NewVnc()
    {
        // Reuse the ad-hoc setup sheet so the host field gets the ZeroTier globe picker.
        if (AdHocConnectionRequested is null) return;
        var r = await AdHocConnectionRequested(AdHocConnectionKind.Vnc, null);
        if (r is null) return;
        OpenVncDirectTab(r.Host, r.Port, r.Host);
    }

    // ---- Ad-hoc connections (profile-free tabs, matching the macOS "+" menu) ----

    /// <summary>Presents the ad-hoc connection setup sheet for a given kind; the
    /// View collects host/port/username/password (or returns null on cancel).</summary>
    public event Func<AdHocConnectionKind, AdHocConnectionPrefill?, Task<AdHocConnectionResult?>>? AdHocConnectionRequested;

    /// <summary>Build a throwaway, unsaved profile from host/port/username so the
    /// existing tab launchers can open a profile-free connection — mirrors the
    /// macOS app's ad-hoc tabs.</summary>
    private static SshProfile AdHocProfile(string host, int port, string username, Guid? id = null)
    {
        var h = host.Trim();
        var u = username.Trim();
        return new SshProfile
        {
            Id = id ?? Guid.NewGuid(),
            Host = h,
            Port = port.ToString(),
            Username = u,
            Name = string.IsNullOrEmpty(u) ? h : $"{u}@{h}"
        };
    }

    /// <summary>Open an ad-hoc SSH terminal to a typed host/port with no saved profile.</summary>
    [RelayCommand]
    private async Task NewRemoteTerminal()
    {
        if (AdHocConnectionRequested is null) return;
        var r = await AdHocConnectionRequested(AdHocConnectionKind.Ssh, null);
        if (r is null) return;
        var profile = AdHocProfile(r.Host, r.Port, r.Username);
        if (r.Snippets is { } sn)
            profile.Snippets = sn.Select(s => new CommandSnippet { Label = s.Label, Command = s.Command }).ToList();
        OpenSession(profile,
                    r.Password.Length == 0 ? null : r.Password,
                    runOnConnectOverride: string.IsNullOrWhiteSpace(r.RunOnConnect) ? null : r.RunOnConnect.Trim());
    }

    /// <summary>Open an ad-hoc SFTP browser to a typed host/port with no saved profile.</summary>
    [RelayCommand]
    private async Task NewSftpConnection()
    {
        if (AdHocConnectionRequested is null) return;
        var r = await AdHocConnectionRequested(AdHocConnectionKind.Sftp, null);
        if (r is null) return;
        OpenSftpTab(AdHocProfile(r.Host, r.Port, r.Username),
                    r.Password.Length == 0 ? null : r.Password, adHoc: true);
    }

    /// <summary>Open an ad-hoc direct VNC console to a typed host/port.</summary>
    [RelayCommand]
    private async Task NewVncConnection()
    {
        if (AdHocConnectionRequested is null) return;
        var r = await AdHocConnectionRequested(AdHocConnectionKind.Vnc, null);
        if (r is null) return;
        OpenVncDirectTab(r.Host, r.Port, r.Host);
    }

    /// <summary>Open an ad-hoc MQTT explorer to a typed host/port.</summary>
    [RelayCommand]
    private async Task NewMqttConnection()
    {
        if (AdHocConnectionRequested is null) return;
        var r = await AdHocConnectionRequested(AdHocConnectionKind.Mqtt, null);
        if (r is null) return;
        OpenMqttTab(r.Host, r.Port,
                    string.IsNullOrEmpty(r.Username) ? null : r.Username,
                    r.Password.Length == 0 ? null : r.Password, r.Host);
    }

    /// <summary>Open an ad-hoc Redis browser to a typed host/port.</summary>
    [RelayCommand]
    private async Task NewRedisConnection()
    {
        if (AdHocConnectionRequested is null) return;
        var r = await AdHocConnectionRequested(AdHocConnectionKind.Redis, null);
        if (r is null) return;
        OpenRedisTab(r.Host, r.Port, r.Password.Length == 0 ? null : r.Password, r.Host);
    }

    /// <summary>
    /// Launch the service a forward points at. Service tabs connect to
    /// <c>127.0.0.1:listenPort</c>, i.e. through the (already running) tunnel.
    /// </summary>
    [RelayCommand]
    private void LaunchForward(PortForward? forward)
    {
        if (forward is null || SelectedProfile is not { } profile) return;
        if (!int.TryParse(forward.ListenPort, out var port) || port <= 0)
        {
            SetStatus("This forward has no listen port.");
            return;
        }
        const string host = "127.0.0.1";
        var name = string.IsNullOrWhiteSpace(forward.Name) ? profile.Name : forward.Name;

        switch (forward.Category)
        {
            case ForwardCategory.Mqtt:
                OpenMqttTab(host, port, string.IsNullOrWhiteSpace(forward.ServiceUsername) ? null : forward.ServiceUsername, _secrets.Get(forward.Id), name);
                break;
            case ForwardCategory.Redis:
                OpenRedisTab(host, port, _secrets.Get(forward.Id), name);
                break;
            case ForwardCategory.Webpage:
                OpenExternalUrl($"http://{host}:{port}");
                break;
            default:
                SetStatus("This forward isn't launchable.");
                break;
        }
    }

    [RelayCommand]
    private void OpenLink(ProfileLink? link)
    {
        if (link is null || string.IsNullOrWhiteSpace(link.Url)) return;
        OpenExternalUrl(link.Url.Trim());
    }

    private void OpenExternalUrl(string url)
    {
        try
        {
            if (!url.Contains("://")) url = "http://" + url;
            var psi = new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true };
            System.Diagnostics.Process.Start(psi);
            SetStatus("Opened " + url);
        }
        catch (Exception ex)
        {
            SetStatus("Could not open link: " + ex.Message);
        }
    }

    [RelayCommand]
    private void ShowProfileList()
    {
        SelectedTab = null;
    }

    /// <summary>Open (connect) every profile in a named group — a lightweight "workspace".</summary>
    public void OpenGroup(string group)
    {
        var members = _store.Profiles
            .Where(p => string.Equals(p.Group, group, StringComparison.OrdinalIgnoreCase))
            .ToList();
        foreach (var p in members)
            OpenSession(p);
        if (members.Count > 1) IsTiled = true;
        SetStatus($"Opened workspace \u201c{group}\u201d ({members.Count}).");
    }

    // ---- Import / Export ----

    [RelayCommand]
    private async Task ImportProfiles()
    {
        if (ImportFileRequested is null) return;
        var path = await ImportFileRequested();
        if (string.IsNullOrEmpty(path)) return;
        try
        {
            var json = await File.ReadAllTextAsync(path);
            var count = _store.ImportJson(json);
            ReloadProfiles();
            SetStatus($"Imported {count} profile{(count == 1 ? "" : "s")}.");
        }
        catch (Exception ex)
        {
            SetStatus("Import failed: " + ex.Message);
        }
    }

    [RelayCommand]
    private async Task ExportProfiles()
    {
        if (ExportFileRequested is null) return;
        var path = await ExportFileRequested("RemoteStuff-profiles.json");
        if (string.IsNullOrEmpty(path)) return;
        try
        {
            await File.WriteAllTextAsync(path, _store.ExportJson());
            SetStatus($"Exported {Profiles.Count} profiles.");
        }
        catch (Exception ex)
        {
            SetStatus("Export failed: " + ex.Message);
        }
    }

    [RelayCommand]
    private void ImportSshConfig()
    {
        try
        {
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var cfg = Path.Combine(home, ".ssh", "config");
            if (!File.Exists(cfg))
            {
                SetStatus("No ~/.ssh/config found.");
                return;
            }
            var parsed = SshConfigImporter.Parse(File.ReadAllText(cfg));
            var count = _store.ImportProfiles(parsed);
            ReloadProfiles();
            SetStatus($"Imported {count} host{(count == 1 ? "" : "s")} from ~/.ssh/config.");
        }
        catch (Exception ex)
        {
            SetStatus("SSH config import failed: " + ex.Message);
        }
    }

    // ---- Command palette ----

    [RelayCommand]
    private void OpenPalette()
    {
        PaletteQuery = "";
        RebuildPalette();
        IsPaletteOpen = true;
    }

    [RelayCommand]
    private void ClosePalette() => IsPaletteOpen = false;

    partial void OnPaletteQueryChanged(string value) => RebuildPalette();

    private void RebuildPalette()
    {
        var q = PaletteQuery?.Trim() ?? "";
        PaletteResults.Clear();

        var actions = new List<PaletteItem>
        {
            new() { Title = "New Remote Terminal", Subtitle = "Create a remote terminal connection", Run = () => NewRemoteTerminalCommand.Execute(null) },
            new() { Title = "New profile…", Subtitle = "Create a saved connection profile", Run = () => NewProfileCommand.Execute(null) },
            new() { Title = "New local shell", Subtitle = "Open your login shell", Run = () => NewLocalShellCommand.Execute(null) },
            new() { Title = "New editor", Subtitle = "Open a blank text editor", Run = () => NewEditorCommand.Execute(null) },
            new() { Title = "New spreadsheet", Subtitle = "Open a CSV / Excel spreadsheet editor", Run = () => NewSpreadsheetCommand.Execute(null) },
            new() { Title = "New Finder", Subtitle = "Browse local files", Run = () => NewFinderCommand.Execute(null) },
            new() { Title = "Network browser", Subtitle = "Interfaces, gateway, DNS and a LAN scanner", Run = () => NewNetworkCommand.Execute(null) },
            new() { Title = "MikroTik router", Subtitle = "RouterOS REST explorer (interfaces, DHCP, config)", Run = () => NewMikroTikCommand.Execute(null) },
            new() { Title = "ZeroTier panel", Subtitle = "Networks & online devices", Run = () => ToggleZeroTierCommand.Execute(null) },
            new() { Title = "New browser", Subtitle = "Open the in-app web browser", Run = () => NewBrowserCommand.Execute(null) },
            new() { Title = "New VNC connection…", Subtitle = "Open a direct VNC console (host:port)", Run = () => NewVncCommand.Execute(null) },
            new() { Title = "Toggle tiling", Subtitle = "Show tabs side-by-side", Run = () => ToggleTileCommand.Execute(null) },
            new() { Title = "New workspace", Subtitle = "Add a fresh tab collection", Run = () => NewWorkspaceCommand.Execute(null) },
            new() { Title = "Next workspace", Subtitle = "Switch to the next workspace", Run = () => NextWorkspaceCommand.Execute(null) },
            new() { Title = "Previous workspace", Subtitle = "Switch to the previous workspace", Run = () => PreviousWorkspaceCommand.Execute(null) },
            new() { Title = "Reopen last closed tab", Subtitle = "Restore a recently closed tab", Run = () => ReopenClosedCommand.Execute(null) },
            new() { Title = "Preferences…", Subtitle = "Open app settings", Run = () => OpenSettingsCommand.Execute(null) },
            new() { Title = "Help…", Subtitle = "Open the in-app guide to every feature", Run = () => OpenHelpCommand.Execute(null) },
            new() { Title = "Manage Known Hosts…", Subtitle = "Browse, filter and remove ~/.ssh/known_hosts entries", Run = () => OpenKnownHostsCommand.Execute(null) },            new() { Title = "Set Up Passwordless Login", Subtitle = "Copy your SSH key to the selected server (ssh-copy-id)", Run = () => SetupPasswordlessLoginCommand.Execute(null) },
            new() { Title = "Toggle broadcast input", Subtitle = "Type to all terminals in this workspace", Run = () => ToggleBroadcastCommand.Execute(null) },
            new() { Title = "Copy terminal scrollback", Subtitle = "Copy the active terminal's output", Run = () => CopyTerminalScrollbackCommand.Execute(null) },
            new() { Title = "Save terminal log…", Subtitle = "Write the active terminal's output to a file", Run = () => SaveTerminalScrollbackCommand.Execute(null) },
            new() { Title = "Disconnect all sessions", Subtitle = "Terminate every live terminal", Run = () => DisconnectAllCommand.Execute(null) },
            new() { Title = "Import profiles…", Subtitle = "From a JSON file", Run = () => ImportProfilesCommand.Execute(null) },
            new() { Title = "Export profiles…", Subtitle = "To a JSON file", Run = () => ExportProfilesCommand.Execute(null) },
            new() { Title = "Import from ~/.ssh/config", Subtitle = "SSH config hosts", Run = () => ImportSshConfigCommand.Execute(null) },
        };

        foreach (var tpl in _store.WorkspaceTemplates)
        {
            var t = tpl;
            actions.Add(new PaletteItem
            {
                Title = "Open saved workspace: " + t.Name,
                Subtitle = $"{t.ProfileIds.Count} tab(s)",
                Run = () => OpenWorkspaceTemplate(t)
            });
        }

        foreach (var group in Profiles
                     .Select(p => p.Group)
                     .Where(g => !string.IsNullOrWhiteSpace(g))
                     .Distinct(StringComparer.OrdinalIgnoreCase))
        {
            var g = group;
            actions.Add(new PaletteItem
            {
                Title = "Open workspace: " + g,
                Subtitle = "Connect all profiles in this group",
                Run = () => OpenGroup(g)
            });
        }

        foreach (var p in Profiles)
        {
            var profile = p;
            actions.Add(new PaletteItem
            {
                Title = "Connect: " + profile.Name,
                Subtitle = profile.Subtitle,
                Run = () => OpenSession(profile)
            });
            if (!profile.IsLocal)
                actions.Add(new PaletteItem
                {
                    Title = "SFTP: " + profile.Name,
                    Subtitle = profile.Subtitle,
                    Run = () => OpenSftpTab(profile)
                });
            if (!profile.IsLocal)
                actions.Add(new PaletteItem
                {
                    Title = "VNC: " + profile.Name,
                    Subtitle = profile.Subtitle,
                    Run = () => OpenVncTab(profile)
                });
        }

        // Snippets from open terminals + saved profiles: insert into the active terminal.
        var seenSnippets = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var snippet in Tabs.OfType<TerminalTabViewModel>().SelectMany(t => t.Snippets)
                     .Concat(_store.Profiles.SelectMany(p => p.Snippets)))
        {
            if (string.IsNullOrWhiteSpace(snippet.Command)) continue;
            var key = (snippet.Label ?? "") + "\u0000" + snippet.Command;
            if (!seenSnippets.Add(key)) continue;
            var s = snippet;
            actions.Add(new PaletteItem
            {
                Title = "Snippet: " + (string.IsNullOrWhiteSpace(s.Label) ? s.Command : s.Label),
                Subtitle = s.Command,
                Run = () => RunSnippetInActive(s)
            });
        }

        // Cross-terminal command history: re-run any past command in the active terminal.
        var seenHistory = new HashSet<string>(StringComparer.Ordinal);
        foreach (var line in Tabs.OfType<TerminalTabViewModel>().SelectMany(t => t.History))
        {
            if (string.IsNullOrWhiteSpace(line) || !seenHistory.Add(line)) continue;
            var cmd = line;
            actions.Add(new PaletteItem
            {
                Title = "History: " + cmd,
                Subtitle = "Re-run in the active terminal",
                Run = () => RunHistoryInActive(cmd)
            });
        }

        IEnumerable<PaletteItem> filtered = actions;
        if (q.Length > 0)
            filtered = actions.Where(a =>
                a.Title.Contains(q, StringComparison.OrdinalIgnoreCase) ||
                a.Subtitle.Contains(q, StringComparison.OrdinalIgnoreCase));

        foreach (var a in filtered)
            PaletteResults.Add(a);

        SelectedPaletteItem = PaletteResults.Count > 0 ? PaletteResults[0] : null;
    }

    [RelayCommand]
    private void RunPaletteItem(PaletteItem? item)
    {
        item ??= SelectedPaletteItem;
        IsPaletteOpen = false;
        item?.Run();
    }
}

/// <summary>A single profile entry in a New ▸ Terminal/SFTP/VNC submenu.</summary>
public sealed class ProfileMenuItem
{
    public string Name { get; }
    public IRelayCommand Command { get; }

    public ProfileMenuItem(string name, Action action)
    {
        Name = name;
        Command = new RelayCommand(action);
    }
}

/// <summary>The profile-free connection kinds the ad-hoc "New …" setup sheet can
/// open, mirroring the macOS app's "+" menu.</summary>
public enum AdHocConnectionKind { Ssh, Sftp, Vnc, Mqtt, Redis }

/// <summary>The connection details typed into the ad-hoc setup sheet. For ssh the
/// optional <paramref name="RunOnConnect"/> is a command auto-run once connected.</summary>
public sealed record AdHocConnectionResult(string Host, int Port, string Username, string Password, string RunOnConnect = "", IReadOnlyList<CommandSnippet>? Snippets = null);

/// <summary>Pre-fills the ad-hoc setup sheet when it's reused to *edit* an existing
/// tab's connection (right-click "Edit Connection Settings…") rather than create a
/// new one. <paramref name="IsEdit"/> switches the sheet's title / confirm button.</summary>
public sealed record AdHocConnectionPrefill(string Host, int Port, string Username, string RunOnConnect, bool IsEdit, IReadOnlyList<CommandSnippet>? Snippets = null);
