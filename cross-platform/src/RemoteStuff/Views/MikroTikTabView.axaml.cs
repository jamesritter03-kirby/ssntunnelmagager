using Avalonia.Controls;
using Avalonia.Markup.Xaml;

namespace RemoteStuff.Views;

public partial class MikroTikTabView : UserControl
{
    public MikroTikTabView()
    {
        InitializeComponent();
    }

    private void InitializeComponent() => AvaloniaXamlLoader.Load(this);
}
