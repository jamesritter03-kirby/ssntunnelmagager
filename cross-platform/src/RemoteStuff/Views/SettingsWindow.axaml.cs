using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Markup.Xaml;
using RemoteStuff.ViewModels;

namespace RemoteStuff.Views;

public partial class SettingsWindow : Window
{
    public SettingsWindow()
    {
        InitializeComponent();
    }

    private void InitializeComponent() => AvaloniaXamlLoader.Load(this);

    private void OnSave(object? sender, RoutedEventArgs e)
    {
        (DataContext as SettingsViewModel)?.Apply();
        Close();
    }

    private void OnCancel(object? sender, RoutedEventArgs e)
    {
        (DataContext as SettingsViewModel)?.RevertThemePreview();
        Close();
    }
}
