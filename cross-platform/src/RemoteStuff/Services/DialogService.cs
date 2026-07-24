using System.Collections.Generic;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Platform.Storage;

namespace RemoteStuff.Services;

/// <summary>
/// A small app-wide helper that exposes the platform file/folder pickers to
/// view-models via the main window's <see cref="TopLevel"/>.
/// </summary>
public static class DialogService
{
    public static TopLevel? Top { get; set; }

    public static async Task<string?> OpenFileAsync(string title = "Open file")
    {
        if (Top is null) return null;
        var files = await Top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = title,
            AllowMultiple = false
        });
        return files.Count > 0 ? files[0].TryGetLocalPath() : null;
    }

    public static async Task<string?> SaveFileAsync(string suggestedName, string title = "Save file")
    {
        if (Top is null) return null;
        var file = await Top.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = title,
            SuggestedFileName = suggestedName
        });
        return file?.TryGetLocalPath();
    }

    public static async Task<string?> OpenFolderAsync(string title = "Choose folder")
    {
        if (Top is null) return null;
        var folders = await Top.StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions
        {
            Title = title,
            AllowMultiple = false
        });
        return folders.Count > 0 ? folders[0].TryGetLocalPath() : null;
    }

    /// <summary>Show a small modal yes/no confirmation. Returns true if the user confirmed.</summary>
    public static async Task<bool> ConfirmAsync(string title, string prompt,
        string confirmText = "OK", string cancelText = "Cancel")
    {
        if (Top is not Window owner) return false;

        var ok = new Button { Content = confirmText, IsDefault = true, MinWidth = 72 };
        var cancel = new Button { Content = cancelText, IsCancel = true, MinWidth = 72 };

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Spacing = 8,
            Margin = new Thickness(0, 12, 0, 0)
        };
        buttons.Children.Add(cancel);
        buttons.Children.Add(ok);

        var panel = new StackPanel { Margin = new Thickness(16), Spacing = 8 };
        panel.Children.Add(new TextBlock { Text = prompt, MaxWidth = 360, TextWrapping = Avalonia.Media.TextWrapping.Wrap });
        panel.Children.Add(buttons);

        var dlg = new Window
        {
            Title = title,
            Content = panel,
            SizeToContent = SizeToContent.WidthAndHeight,
            CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ShowInTaskbar = false
        };

        ok.Click += (_, _) => dlg.Close(true);
        cancel.Click += (_, _) => dlg.Close(false);

        return await dlg.ShowDialog<bool>(owner);
    }

    /// <summary>Show a small modal text prompt. Returns the entered text, or null if cancelled.</summary>
    public static async Task<string?> PromptTextAsync(string title, string prompt, string initial = "")
    {
        if (Top is not Window owner) return null;

        var box = new TextBox
        {
            Text = initial,
            MinWidth = 340,
            AcceptsReturn = false
        };

        var ok = new Button { Content = "OK", IsDefault = true, MinWidth = 72 };
        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 72 };

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Spacing = 8,
            Margin = new Thickness(0, 12, 0, 0)
        };
        buttons.Children.Add(cancel);
        buttons.Children.Add(ok);

        var panel = new StackPanel { Margin = new Thickness(16), Spacing = 8 };
        panel.Children.Add(new TextBlock { Text = prompt });
        panel.Children.Add(box);
        panel.Children.Add(buttons);

        var dlg = new Window
        {
            Title = title,
            Content = panel,
            SizeToContent = SizeToContent.WidthAndHeight,
            CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ShowInTaskbar = false
        };

        ok.Click += (_, _) => dlg.Close(box.Text ?? "");
        cancel.Click += (_, _) => dlg.Close(null);

        box.Focus();
        box.SelectAll();
        return await dlg.ShowDialog<string?>(owner);
    }
}
