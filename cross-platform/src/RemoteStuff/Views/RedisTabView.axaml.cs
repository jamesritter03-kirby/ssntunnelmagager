using Avalonia.Controls;
using Avalonia.Markup.Xaml;

namespace RemoteStuff.Views;

public partial class RedisTabView : UserControl
{
    public RedisTabView()
    {
        InitializeComponent();
    }

    private void InitializeComponent() => AvaloniaXamlLoader.Load(this);
}
