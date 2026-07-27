using Avalonia.Controls;
using RemoteStuff.ViewModels;

namespace RemoteStuff.Views;

public partial class PropagateCollectionWindow : Window
{
    public PropagateCollectionWindow()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
    }

    private void OnDataContextChanged(object? sender, System.EventArgs e)
    {
        if (DataContext is PropagateCollectionViewModel vm)
            vm.CloseRequested += Close;
    }
}
