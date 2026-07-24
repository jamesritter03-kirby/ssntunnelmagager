using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Markup.Xaml;

namespace RemoteStuff.Views;

public partial class DetachedTerminalWindow : Window
{
    public DetachedTerminalWindow()
    {
        InitializeComponent();
    }

    private void InitializeComponent() => AvaloniaXamlLoader.Load(this);

    protected override void OnApplyTemplate(Avalonia.Controls.Primitives.TemplateAppliedEventArgs e)
    {
        base.OnApplyTemplate(e);
        if (this.FindControl<Avalonia.Controls.Primitives.ToggleButton>("PinButton") is { } pin)
            pin.IsCheckedChanged += (_, _) => Topmost = pin.IsChecked == true;
    }
}
