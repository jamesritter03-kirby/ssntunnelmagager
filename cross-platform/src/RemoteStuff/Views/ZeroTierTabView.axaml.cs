using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
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

    // Double-clicking anywhere on a network card collapses / expands it, in
    // addition to the chevron button. Taps that land on interactive controls
    // (buttons, toggles, text boxes) are ignored so member actions and copy
    // buttons keep working.
    private void OnNetworkDoubleTapped(object? sender, TappedEventArgs e)
    {
        if (sender is not Control card || card.DataContext is not ZtNetworkRowViewModel vm)
            return;
        if (e.Source is Control source && IsInteractive(source, card))
            return;
        vm.ToggleCollapseCommand.Execute(null);
    }

    private static bool IsInteractive(Control source, Control stopAt)
    {
        for (var current = source; current is not null && current != stopAt; current = current.Parent as Control)
        {
            if (current is Button or ToggleButton or TextBox or CheckBox)
                return true;
        }
        return false;
    }
}
