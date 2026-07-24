using Avalonia.Controls;
using Avalonia.Markup.Xaml;

namespace RemoteStuff.Views;

public partial class VncTabView : UserControl
{
    public VncTabView()
    {
        InitializeComponent();
    }

    private void InitializeComponent() => AvaloniaXamlLoader.Load(this);
}
