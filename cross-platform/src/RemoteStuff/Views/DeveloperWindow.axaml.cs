using Avalonia.Controls;
using RemoteStuff.ViewModels;

namespace RemoteStuff.Views;

public partial class DeveloperWindow : Window
{
    public DeveloperWindow()
    {
        InitializeComponent();
        Closed += (_, _) => (DataContext as DeveloperViewModel)?.Stop();
    }
}
