using Avalonia.Controls;
using Avalonia.Markup.Xaml;

namespace RemoteStuff.Views;

public partial class BrowserTabView : UserControl
{
    public BrowserTabView()
    {
        InitializeComponent();
    }

    private void InitializeComponent() => AvaloniaXamlLoader.Load(this);
}
