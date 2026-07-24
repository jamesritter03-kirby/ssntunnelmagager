using System;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Markup.Xaml;
using Avalonia.Platform.Storage;
using Avalonia.VisualTree;
using RemoteStuff.ViewModels;

namespace RemoteStuff.Views;

public partial class SftpTabView : UserControl
{
    private SftpTabViewModel? _vm;

    // Drag-and-drop payload formats shared with FinderTabView.
    internal const string LocalPathFormat = "remotestuff-local-path";
    internal const string SftpDragFormat = "remotestuff-sftp-drag";

    private Point _pressPos;
    private bool _dragArmed;
    private SftpEntryViewModel? _pressEntry;

    public SftpTabView()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;

        if (this.FindControl<ListBox>("EntryList") is { } list)
        {
            list.AddHandler(PointerPressedEvent, OnListPointerPressed, RoutingStrategies.Tunnel);
            list.AddHandler(PointerMovedEvent, OnListPointerMoved, RoutingStrategies.Tunnel);
            DragDrop.SetAllowDrop(list, true);
            list.AddHandler(DragDrop.DragOverEvent, OnDragOver);
            list.AddHandler(DragDrop.DropEvent, OnDrop);
        }
    }

    private void InitializeComponent() => AvaloniaXamlLoader.Load(this);

    private void OnDataContextChanged(object? sender, EventArgs e)
    {
        if (_vm != null)
            _vm.NameRequested -= PromptForName;
        _vm = DataContext as SftpTabViewModel;
        if (_vm != null)
            _vm.NameRequested += PromptForName;
    }

    // ---- Drag source: drag an SFTP row out to the Finder panel to download ----

    private void OnListPointerPressed(object? sender, PointerPressedEventArgs e)
    {
        var pt = e.GetCurrentPoint(sender as Visual);
        if (!pt.Properties.IsLeftButtonPressed) { _dragArmed = false; return; }
        _pressEntry = (e.Source as Control)?.DataContext as SftpEntryViewModel
                      ?? FindEntry(e.Source as Visual);
        _pressPos = pt.Position;
        _dragArmed = _pressEntry is { IsParent: false };
    }

    private async void OnListPointerMoved(object? sender, PointerEventArgs e)
    {
        if (!_dragArmed || _pressEntry is null || _vm is null) return;
        var pt = e.GetCurrentPoint(sender as Visual);
        if (!pt.Properties.IsLeftButtonPressed) { _dragArmed = false; return; }
        var d = pt.Position - _pressPos;
        if (Math.Abs(d.X) < 6 && Math.Abs(d.Y) < 6) return;
        _dragArmed = false;

        var data = new DataObject();
        data.Set(SftpDragFormat, new SftpDragData(_vm, _pressEntry));
        try { await DragDrop.DoDragDrop(e, data, DragDropEffects.Copy); }
        catch { /* drag cancelled */ }
    }

    private static SftpEntryViewModel? FindEntry(Visual? from)
    {
        var item = from?.FindAncestorOfType<ListBoxItem>();
        return item?.DataContext as SftpEntryViewModel;
    }

    // ---- Drop target: drop a local file/folder here to upload ----

    private void OnDragOver(object? sender, DragEventArgs e)
    {
        e.DragEffects = e.Data.Contains(LocalPathFormat) || e.Data.Contains(DataFormats.Files)
            ? DragDropEffects.Copy
            : DragDropEffects.None;
        e.Handled = true;
    }

    private async void OnDrop(object? sender, DragEventArgs e)
    {
        e.Handled = true;
        var vm = _vm;
        if (vm is null) return;
        // async-void handler: any escaping exception (a dropped Finder file that fails
        // to upload, a dropped item with no local path, a disconnected session) would
        // otherwise be unhandled and abort the whole process. Contain it here.
        try
        {
            if (e.Data.Get(LocalPathFormat) is string localPath)
            {
                await vm.UploadLocalPathAsync(localPath);
            }
            else if (e.Data.GetFiles() is { } files)
            {
                foreach (var f in files)
                    if (f.TryGetLocalPath() is { } p)
                        await vm.UploadLocalPathAsync(p);
            }
        }
        catch (Exception ex)
        {
            vm.StatusText = "Upload failed: " + ex.Message;
        }
    }

    private Task<string?> PromptForName(string title, string current)
    {
        if (TopLevel.GetTopLevel(this) is Window owner)
            return TextPromptWindow.ShowAsync(owner, title, current);
        return Task.FromResult<string?>(null);
    }

    private void OnRowDoubleTapped(object? sender, TappedEventArgs e)
    {
        if (DataContext is SftpTabViewModel vm && vm.OpenCommand.CanExecute(null))
            vm.OpenCommand.Execute(vm.SelectedEntry);
    }

    private void OnPathKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && DataContext is SftpTabViewModel vm)
        {
            e.Handled = true;
            if (vm.GoToPathCommand.CanExecute(null))
                vm.GoToPathCommand.Execute(null);
        }
    }

    private void OnReconnectKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && DataContext is SftpTabViewModel vm)
        {
            e.Handled = true;
            if (vm.ReconnectCommand.CanExecute(null))
                vm.ReconnectCommand.Execute(null);
        }
    }
}
