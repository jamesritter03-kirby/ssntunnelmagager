using System;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Markup.Xaml;
using Avalonia.VisualTree;
using RemoteStuff.ViewModels;

namespace RemoteStuff.Views;

public partial class FinderTabView : UserControl
{
    private Point _pressPos;
    private bool _dragArmed;
    private LocalEntryViewModel? _pressEntry;

    public FinderTabView()
    {
        InitializeComponent();

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

    // ---- Drag source: drag a local row out to the SFTP panel to upload ----

    private void OnListPointerPressed(object? sender, PointerPressedEventArgs e)
    {
        var pt = e.GetCurrentPoint(sender as Visual);
        if (!pt.Properties.IsLeftButtonPressed) { _dragArmed = false; return; }
        _pressEntry = (e.Source as Control)?.DataContext as LocalEntryViewModel
                      ?? FindEntry(e.Source as Visual);
        _pressPos = pt.Position;
        _dragArmed = _pressEntry is { IsParent: false };
    }

    private async void OnListPointerMoved(object? sender, PointerEventArgs e)
    {
        if (!_dragArmed || _pressEntry is null) return;
        var pt = e.GetCurrentPoint(sender as Visual);
        if (!pt.Properties.IsLeftButtonPressed) { _dragArmed = false; return; }
        var d = pt.Position - _pressPos;
        if (Math.Abs(d.X) < 6 && Math.Abs(d.Y) < 6) return;
        _dragArmed = false;

        var data = new DataObject();
        data.Set(SftpTabView.LocalPathFormat, _pressEntry.FullPath);
        try { await DragDrop.DoDragDrop(e, data, DragDropEffects.Copy); }
        catch { /* drag cancelled */ }
    }

    private static LocalEntryViewModel? FindEntry(Visual? from)
    {
        var item = from?.FindAncestorOfType<ListBoxItem>();
        return item?.DataContext as LocalEntryViewModel;
    }

    // ---- Drop target: drop an SFTP row here to download ----

    private void OnDragOver(object? sender, DragEventArgs e)
    {
        e.DragEffects = e.Data.Contains(SftpTabView.SftpDragFormat)
            ? DragDropEffects.Copy
            : DragDropEffects.None;
        e.Handled = true;
    }

    private async void OnDrop(object? sender, DragEventArgs e)
    {
        e.Handled = true;
        if (DataContext is not FinderTabViewModel vm) return;
        // async-void handler: contain any exception so a failed download can't abort
        // the process (see SftpTabView.OnDrop).
        try
        {
            if (e.Data.Get(SftpTabView.SftpDragFormat) is SftpDragData sd)
            {
                await sd.Source.DownloadEntryToAsync(sd.Entry, vm.CurrentPath);
                vm.ReloadCurrentDirectory();
            }
        }
        catch (Exception ex)
        {
            vm.StatusText = "Download failed: " + ex.Message;
        }
    }

    private void OnRowDoubleTapped(object? sender, TappedEventArgs e)
    {
        if (DataContext is FinderTabViewModel vm && vm.OpenCommand.CanExecute(null))
            vm.OpenCommand.Execute(vm.SelectedEntry);
    }

    private void OnPathKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && DataContext is FinderTabViewModel vm)
        {
            e.Handled = true;
            if (vm.GoToPathCommand.CanExecute(null))
                vm.GoToPathCommand.Execute(null);
        }
    }
}
