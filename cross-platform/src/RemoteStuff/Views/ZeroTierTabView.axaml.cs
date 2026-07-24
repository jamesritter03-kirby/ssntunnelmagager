using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Markup.Xaml;
using RemoteStuff.ViewModels;

namespace RemoteStuff.Views;

public partial class ZeroTierTabView : UserControl
{
    public ZeroTierTabView()
    {
        InitializeComponent();
    }

    private void InitializeComponent() => AvaloniaXamlLoader.Load(this);

    private void OnManageAccounts(object? sender, RoutedEventArgs e)
    {
        if (DataContext is not ZeroTierTabViewModel vm) return;
        var window = new ZeroTierAccountsWindow { DataContext = vm };
        if (TopLevel.GetTopLevel(this) is Window owner)
            _ = window.ShowDialog(owner);
        else
            window.Show();
    }
}
