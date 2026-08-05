using System.Collections.Generic;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Input.Platform;
using Avalonia.Interactivity;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using Avalonia.VisualTree;
using RemoteStuff.ViewModels;

namespace RemoteStuff.Views;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
        AddHandler(KeyDownEvent, OnPreviewKeyDown, RoutingStrategies.Tunnel);
        SetupTabDrag();
        SetupWorkspaceDrag();
    }

    private MainWindowViewModel? _vm;

    private void OnDataContextChanged(object? sender, System.EventArgs e)
    {
        if (_vm != null)
        {
            _vm.EditProfileRequested -= ShowEditor;
            _vm.CopyToClipboardRequested -= CopyToClipboard;
            _vm.ImportFileRequested -= PickImportFile;
            _vm.ExportFileRequested -= PickExportFile;
            _vm.WorkspaceNameRequested -= PromptForName;
            _vm.AdHocConnectionRequested -= ShowAdHocConnection;
            _vm.SettingsRequested -= ShowSettings;
            _vm.KnownHostsRequested -= ShowKnownHosts;
            _vm.HelpRequested -= ShowHelp;
            _vm.DeveloperToolsRequested -= ShowDeveloperTools;
            _vm.WorkspaceStatsRequested -= ShowWorkspaceStats;
            _vm.CompareProfilesRequested -= ShowCompareProfiles;
            _vm.GitSyncRequested -= ShowGitSync;
            _vm.DetachTerminalRequested -= ShowDetachedTerminal;
            _vm.SessionLogsRequested -= ShowSessionLogs;
            _vm.PropertyChanged -= OnVmPropertyChanged;
        }
        _vm = DataContext as MainWindowViewModel;
        if (_vm != null)
        {
            _vm.EditProfileRequested += ShowEditor;
            _vm.CopyToClipboardRequested += CopyToClipboard;
            _vm.ImportFileRequested += PickImportFile;
            _vm.ExportFileRequested += PickExportFile;
            _vm.WorkspaceNameRequested += PromptForName;
            _vm.AdHocConnectionRequested += ShowAdHocConnection;
            _vm.SettingsRequested += ShowSettings;
            _vm.KnownHostsRequested += ShowKnownHosts;
            _vm.HelpRequested += ShowHelp;
            _vm.DeveloperToolsRequested += ShowDeveloperTools;
            _vm.WorkspaceStatsRequested += ShowWorkspaceStats;
            _vm.CompareProfilesRequested += ShowCompareProfiles;
            _vm.GitSyncRequested += ShowGitSync;
            _vm.DetachTerminalRequested += ShowDetachedTerminal;
            _vm.SessionLogsRequested += ShowSessionLogs;
            _vm.PropertyChanged += OnVmPropertyChanged;
        }
    }

    // Double-clicking a docked panel's header toolbar collapses it to the edge,
    // mirroring the single-click chevron. Ignore double-taps that land on the
    // toolbar's buttons or the browser address box so those keep working.
    private void OnDockHeaderDoubleTapped(object? sender, TappedEventArgs e)
    {
        if (e.Source is Visual v &&
            (v.FindAncestorOfType<Button>(includeSelf: true) is not null ||
             v.FindAncestorOfType<TextBox>(includeSelf: true) is not null))
            return;
        if ((sender as Control)?.DataContext is TabViewModel { IsDocked: true } tab)
            _vm?.CollapseTabDockCommand.Execute(tab);
    }

    // The docked header's right-click menu only offers session logging, which only
    // terminal tabs support. Cancel the request for other tab types so right-clicking
    // their toolbar doesn't pop an empty menu.
    private void OnDockHeaderContextRequested(object? sender, ContextRequestedEventArgs e)
    {
        if ((sender as Control)?.DataContext is not TabViewModel { SupportsTheme: true })
            e.Handled = true;
    }

    /// <summary>Let a vertical mouse wheel scroll the horizontal workspace / tab strips,
    /// matching the macOS app. Trackpads (which already produce a horizontal delta) and
    /// Shift+wheel are left untouched so their native horizontal scrolling still works.</summary>
    private void OnStripPointerWheel(object? sender, PointerWheelEventArgs e)
    {
        if (sender is not Control control) return;
        var scroll = control as ScrollViewer ?? control.FindDescendantOfType<ScrollViewer>();
        if (scroll is null) return;

        // Use whichever wheel axis the device reports the most movement on, so a
        // plain vertical wheel scrolls the row sideways.
        var delta = e.Delta;
        var amount = System.Math.Abs(delta.X) > System.Math.Abs(delta.Y) ? delta.X : delta.Y;
        if (amount == 0) return;

        var max = scroll.Extent.Width - scroll.Viewport.Width;
        if (max <= 0) return; // nothing to scroll horizontally

        const double step = 60;
        var x = scroll.Offset.X - amount * step;
        x = System.Math.Clamp(x, 0, max);
        scroll.Offset = scroll.Offset.WithX(x);
        e.Handled = true;
    }

    private void OnVmPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(MainWindowViewModel.IsPaletteOpen) && _vm?.IsPaletteOpen == true)
        {
            Dispatcher.UIThread.Post(() =>
            {
                if (this.FindControl<TextBox>("PaletteBox") is { } box)
                {
                    box.Focus();
                    box.SelectAll();
                }
            });
        }
        else if (e.PropertyName == nameof(MainWindowViewModel.IsZeroTierVisible))
        {
            UpdateZeroTierColumn();
        }
    }

    // ---- Tab drag-and-drop reorder ----

    private const string TabDragFormat = "remote-stuff-tab";
    private TabViewModel? _dragTab;
    private Point _dragStart;

    private void SetupTabDrag()
    {
        if (this.FindControl<ListBox>("TabStrip") is not { } strip) return;
        strip.AddHandler(PointerPressedEvent, TabStrip_PointerPressed, RoutingStrategies.Tunnel);
        strip.AddHandler(PointerMovedEvent, TabStrip_PointerMoved, RoutingStrategies.Tunnel);
        DragDrop.SetAllowDrop(strip, true);
        strip.AddHandler(DragDrop.DragOverEvent, TabStrip_DragOver);
        strip.AddHandler(DragDrop.DropEvent, TabStrip_Drop);
    }

    private void TabStrip_PointerPressed(object? sender, PointerPressedEventArgs e)
    {
        if (!e.GetCurrentPoint(null).Properties.IsLeftButtonPressed) { _dragTab = null; return; }
        _dragTab = FindTab(e.Source);
        _dragStart = e.GetPosition(null);
    }

    private async void TabStrip_PointerMoved(object? sender, PointerEventArgs e)
    {
        if (_dragTab is null) return;
        if (!e.GetCurrentPoint(null).Properties.IsLeftButtonPressed) { _dragTab = null; return; }
        var pos = e.GetPosition(null);
        if (System.Math.Abs(pos.X - _dragStart.X) < 6 && System.Math.Abs(pos.Y - _dragStart.Y) < 6) return;
        var tab = _dragTab;
        _dragTab = null;
        var data = new DataObject();
        data.Set(TabDragFormat, tab);
        await DragDrop.DoDragDrop(e, data, DragDropEffects.Move);
    }

    private void TabStrip_DragOver(object? sender, DragEventArgs e)
    {
        e.DragEffects = e.Data.Contains(TabDragFormat) ? DragDropEffects.Move : DragDropEffects.None;
    }

    private void TabStrip_Drop(object? sender, DragEventArgs e)
    {
        if (_vm is null || !e.Data.Contains(TabDragFormat)) return;
        if (e.Data.Get(TabDragFormat) is not TabViewModel moved) return;
        if (FindTab(e.Source) is { } target)
            _vm.MoveTab(moved, target);
    }

    /// <summary>Walk up the visual tree from an event source to the owning tab.</summary>
    private static TabViewModel? FindTab(object? source)
    {
        var v = source as Visual;
        while (v is not null)
        {
            if (v is Control { DataContext: TabViewModel t }) return t;
            v = v.GetVisualParent();
        }
        return null;
    }

    // ---- Workspace drag-and-drop reorder ----

    private const string WorkspaceDragFormat = "remote-stuff-workspace";
    private WorkspaceViewModel? _dragWorkspace;
    private Point _dragWorkspaceStart;

    private void SetupWorkspaceDrag()
    {
        if (this.FindControl<ItemsControl>("WorkspaceStrip") is not { } strip) return;
        strip.AddHandler(PointerPressedEvent, WorkspaceStrip_PointerPressed, RoutingStrategies.Tunnel);
        strip.AddHandler(PointerMovedEvent, WorkspaceStrip_PointerMoved, RoutingStrategies.Tunnel);
        DragDrop.SetAllowDrop(strip, true);
        strip.AddHandler(DragDrop.DragOverEvent, WorkspaceStrip_DragOver);
        strip.AddHandler(DragDrop.DropEvent, WorkspaceStrip_Drop);
    }

    private void WorkspaceStrip_PointerPressed(object? sender, PointerPressedEventArgs e)
    {
        if (!e.GetCurrentPoint(null).Properties.IsLeftButtonPressed) { _dragWorkspace = null; return; }
        _dragWorkspace = FindWorkspace(e.Source);
        _dragWorkspaceStart = e.GetPosition(null);
    }

    private async void WorkspaceStrip_PointerMoved(object? sender, PointerEventArgs e)
    {
        if (_dragWorkspace is null) return;
        if (!e.GetCurrentPoint(null).Properties.IsLeftButtonPressed) { _dragWorkspace = null; return; }
        var pos = e.GetPosition(null);
        if (System.Math.Abs(pos.X - _dragWorkspaceStart.X) < 6 && System.Math.Abs(pos.Y - _dragWorkspaceStart.Y) < 6) return;
        var ws = _dragWorkspace;
        _dragWorkspace = null;
        var data = new DataObject();
        data.Set(WorkspaceDragFormat, ws);
        await DragDrop.DoDragDrop(e, data, DragDropEffects.Move);
    }

    private void WorkspaceStrip_DragOver(object? sender, DragEventArgs e)
    {
        e.DragEffects = e.Data.Contains(WorkspaceDragFormat) ? DragDropEffects.Move : DragDropEffects.None;
    }

    private void WorkspaceStrip_Drop(object? sender, DragEventArgs e)
    {
        if (_vm is null || !e.Data.Contains(WorkspaceDragFormat)) return;
        if (e.Data.Get(WorkspaceDragFormat) is not WorkspaceViewModel moved) return;
        if (FindWorkspace(e.Source) is { } target)
            _vm.MoveWorkspace(moved, target);
    }

    /// <summary>Walk up the visual tree from an event source to the owning workspace.</summary>
    private static WorkspaceViewModel? FindWorkspace(object? source)
    {
        var v = source as Visual;
        while (v is not null)
        {
            if (v is Control { DataContext: WorkspaceViewModel w }) return w;
            v = v.GetVisualParent();
        }
        return null;
    }

    private double _lastZeroTierWidth = 400;

    private void UpdateZeroTierColumn()
    {
        if (this.FindControl<Grid>("BodyGrid") is not { } grid || grid.ColumnDefinitions.Count < 4)
            return;
        var col = grid.ColumnDefinitions[3];
        if (_vm?.IsZeroTierVisible == true)
        {
            if (_vm.Settings.ZeroTierPanelWidth > 0)
                _lastZeroTierWidth = _vm.Settings.ZeroTierPanelWidth;
            col.Width = new GridLength(_lastZeroTierWidth);
        }
        else
        {
            if (col.Width.IsAbsolute && col.Width.Value > 0)
            {
                _lastZeroTierWidth = col.Width.Value;
                PersistZeroTierWidth();
            }
            col.Width = new GridLength(0);
        }
    }

    // Remember the ZeroTier panel width across launches.
    private void PersistZeroTierWidth()
    {
        if (_vm is { } vm && _lastZeroTierWidth > 0)
        {
            vm.Settings.ZeroTierPanelWidth = _lastZeroTierWidth;
            vm.Settings.Save();
        }
    }

    protected override void OnClosing(WindowClosingEventArgs e)
    {
        if (_vm?.IsZeroTierVisible == true &&
            this.FindControl<Grid>("BodyGrid") is { } grid && grid.ColumnDefinitions.Count >= 4 &&
            grid.ColumnDefinitions[3].Width is { IsAbsolute: true, Value: > 0 } w)
        {
            _lastZeroTierWidth = w.Value;
        }
        PersistZeroTierWidth();
        base.OnClosing(e);
    }

    private void OnPreviewKeyDown(object? sender, KeyEventArgs e)
    {
        if (_vm is null || !_vm.IsPaletteOpen) return;
        switch (e.Key)
        {
            case Key.Escape:
                _vm.ClosePaletteCommand.Execute(null);
                e.Handled = true;
                break;
            case Key.Enter:
                _vm.RunPaletteItemCommand.Execute(null);
                e.Handled = true;
                break;
            case Key.Down:
                MovePaletteSelection(1);
                e.Handled = true;
                break;
            case Key.Up:
                MovePaletteSelection(-1);
                e.Handled = true;
                break;
        }
    }

    private void MovePaletteSelection(int delta)
    {
        if (_vm is null) return;
        var results = _vm.PaletteResults;
        var actionIndices = new List<int>();
        for (var i = 0; i < results.Count; i++)
            if (results[i].IsAction) actionIndices.Add(i);
        if (actionIndices.Count == 0) return;

        var current = _vm.SelectedPaletteItem is null ? -1 : results.IndexOf(_vm.SelectedPaletteItem);
        var pos = actionIndices.IndexOf(current);
        if (pos < 0) pos = delta > 0 ? -1 : actionIndices.Count;
        pos = System.Math.Clamp(pos + delta, 0, actionIndices.Count - 1);
        _vm.SelectedPaletteItem = results[actionIndices[pos]];
    }

    // Double-clicking a palette row runs it (single Enter also works).
    private void OnPaletteItemActivated(object? sender, TappedEventArgs e)
    {
        if ((sender as Control)?.DataContext is PaletteItem item && _vm is not null)
            _vm.RunPaletteItemCommand.Execute(item);
    }

    /// <summary>Double-clicking a sidebar row connects to it (matches the Mac app).</summary>
    private void OnProfileRowDoubleTapped(object? sender, TappedEventArgs e)
    {
        if (sender is Control { DataContext: ProfileRowViewModel row } && _vm is not null)
            _vm.ConnectRow(row);
    }

    /// <summary>Dragging the sidebar's right edge resizes it.</summary>
    private void OnSidebarResize(object? sender, VectorEventArgs e)
    {
        if (_vm is not null)
            _vm.ExpandedSidebarWidth += e.Vector.X;
    }

    private async void ShowEditor(ProfileEditorViewModel editor)
    {
        var window = new ProfileEditorWindow { DataContext = editor };
        await window.ShowDialog(this);
    }

    private Task<string?> PromptForName(string title, string current)
        => TextPromptWindow.ShowAsync(this, title, current);

    private Task<AdHocConnectionResult?> ShowAdHocConnection(AdHocConnectionKind kind, AdHocConnectionPrefill? prefill)
        => AdHocConnectionWindow.ShowAsync(this, kind, prefill);

    private async void ShowSettings(SettingsViewModel vm)
    {
        var window = new SettingsWindow { DataContext = vm };
        await window.ShowDialog(this);
    }

    private async void ShowKnownHosts()
    {
        var window = new KnownHostsWindow { DataContext = new KnownHostsViewModel() };
        await window.ShowDialog(this);
    }

    private void ShowHelp()
    {
        var window = new HelpWindow();
        window.Show(this);
    }

    private void ShowDeveloperTools(DeveloperViewModel vm)
    {
        var window = new DeveloperWindow { DataContext = vm };
        window.Show(this);
    }

    private void ShowWorkspaceStats(WorkspaceStatsViewModel vm)
    {
        var window = new WorkspaceStatsWindow { DataContext = vm };
        window.Show(this);
    }

    private void ShowCompareProfiles(ProfileComparisonViewModel vm)
    {
        var window = new ProfileComparisonWindow { DataContext = vm };
        window.Show(this);
    }

    private void ShowGitSync(GitSyncViewModel vm)
    {
        var window = new GitSyncWindow { DataContext = vm };
        window.Show(this);
    }

    private void ShowSessionLogs(SessionLogsViewModel vm)
    {
        var window = new SessionLogsWindow { DataContext = vm };
        window.Show(this);
    }

    private void ShowDetachedTerminal(TerminalTabViewModel term)
    {
        var window = new DetachedTerminalWindow { DataContext = term };
        window.Closed += (_, _) => _vm?.ReattachTab(term);
        window.Show();
    }

    private async void CopyToClipboard(string text)
    {
        if (Clipboard is { } cb)
            await cb.SetTextAsync(text);
    }

    private async Task<string?> PickImportFile()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Import profiles",
            AllowMultiple = false,
            FileTypeFilter = new[]
            {
                new FilePickerFileType("JSON") { Patterns = new[] { "*.json" } },
                FilePickerFileTypes.All
            }
        });
        return files.Count > 0 ? files[0].TryGetLocalPath() : null;
    }

    private async Task<string?> PickExportFile(string suggestedName)
    {
        var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Export profiles",
            SuggestedFileName = suggestedName,
            DefaultExtension = "json",
            FileTypeChoices = new[]
            {
                new FilePickerFileType("JSON") { Patterns = new[] { "*.json" } }
            }
        });
        return file?.TryGetLocalPath();
    }
}
