using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;

namespace RemoteStuff.Views;

/// <summary>A tiny modal text-input dialog returning the entered string, or null on cancel.</summary>
public sealed class TextPromptWindow : Window
{
    private readonly TextBox _box;
    private string? _result;

    private TextPromptWindow(string title, string current)
    {
        Title = title;
        Width = 380;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        CanResize = false;
        Background = new SolidColorBrush(Color.Parse("#1E1E1E"));

        _box = new TextBox { Text = current, Watermark = "Name" };
        _box.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter) Accept();
            else if (e.Key == Key.Escape) Close();
        };

        var ok = new Button { Content = "OK", Padding = new Thickness(16, 6), IsDefault = true };
        ok.Click += (_, _) => Accept();
        var cancel = new Button { Content = "Cancel", Padding = new Thickness(16, 6), IsCancel = true };
        cancel.Click += (_, _) => Close();

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Spacing = 8
        };
        buttons.Children.Add(cancel);
        buttons.Children.Add(ok);

        var root = new StackPanel { Margin = new Thickness(16), Spacing = 12 };
        root.Children.Add(new TextBlock { Text = title, FontWeight = FontWeight.Bold });
        root.Children.Add(_box);
        root.Children.Add(buttons);
        Content = root;

        Opened += (_, _) => { _box.Focus(); _box.SelectAll(); };
    }

    private void Accept()
    {
        _result = _box.Text;
        Close();
    }

    public static async Task<string?> ShowAsync(Window owner, string title, string current)
    {
        var dlg = new TextPromptWindow(title, current);
        await dlg.ShowDialog(owner);
        return dlg._result;
    }
}
