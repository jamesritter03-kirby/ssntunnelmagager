using Avalonia.Controls;
using RemoteStuff.ViewModels;

namespace RemoteStuff.Views;

public partial class WorkspaceStatsWindow : Window
{
    public WorkspaceStatsWindow()
    {
        InitializeComponent();
        Closed += (_, _) => (DataContext as WorkspaceStatsViewModel)?.Stop();
    }
}
