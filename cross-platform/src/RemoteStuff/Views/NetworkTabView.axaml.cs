using Avalonia.Controls;
using Avalonia.Markup.Xaml;

namespace RemoteStuff.Views;

public partial class NetworkTabView : UserControl
{
    public NetworkTabView()
    {
        InitializeComponent();
    }

    private void InitializeComponent() => AvaloniaXamlLoader.Load(this);
}
