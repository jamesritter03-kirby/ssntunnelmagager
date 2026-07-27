using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using RemoteStuff.ViewModels;

namespace RemoteStuff.Views;

public partial class ProfileComparisonWindow : Window
{
    private const double MinColumnWidth = 70;
    private const double MaxColumnWidth = 640;

    public ProfileComparisonWindow()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
    }

    private void OnDataContextChanged(object? sender, System.EventArgs e)
    {
        if (DataContext is ProfileComparisonViewModel vm)
            vm.CopyListsRequested += ShowCopyLists;
    }

    private void ShowCopyLists(PropagateCollectionViewModel vm)
    {
        var window = new PropagateCollectionWindow { DataContext = vm };
        window.Show(this);
    }

    /// <summary>Live-resize a column while its header handle is dragged.</summary>
    private void OnColumnDragDelta(object? sender, VectorEventArgs e)
    {
        if (sender is Control { DataContext: ComparisonColumn column })
            column.Width = System.Math.Clamp(column.Width + e.Vector.X, MinColumnWidth, MaxColumnWidth);
    }

    /// <summary>Persist the widths once a resize drag finishes.</summary>
    private void OnColumnDragCompleted(object? sender, VectorEventArgs e)
    {
        (DataContext as ProfileComparisonViewModel)?.SaveColumnWidths();
    }
}
