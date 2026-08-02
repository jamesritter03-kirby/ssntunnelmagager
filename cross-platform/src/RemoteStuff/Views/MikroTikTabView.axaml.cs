using System;
using System.Threading.Tasks;
using Avalonia.Controls;
using Avalonia.Markup.Xaml;
using Avalonia.Platform.Storage;
using RemoteStuff.ViewModels;

namespace RemoteStuff.Views;

public partial class MikroTikTabView : UserControl
{
    private MikroTikTabViewModel? _hooked;

    public MikroTikTabView()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
    }

    private void InitializeComponent() => AvaloniaXamlLoader.Load(this);

    private void OnDataContextChanged(object? sender, EventArgs e)
    {
        if (_hooked is not null) _hooked.SaveFileRequested -= PickSaveFile;
        _hooked = DataContext as MikroTikTabViewModel;
        if (_hooked is not null) _hooked.SaveFileRequested += PickSaveFile;
    }

    private async Task<string?> PickSaveFile(string suggestedName)
    {
        if (TopLevel.GetTopLevel(this)?.StorageProvider is not { } sp) return null;
        var file = await sp.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Save RouterOS config",
            SuggestedFileName = suggestedName,
            DefaultExtension = "rsc",
            FileTypeChoices = new[]
            {
                new FilePickerFileType("RouterOS script") { Patterns = new[] { "*.rsc" } },
                new FilePickerFileType("All files") { Patterns = new[] { "*" } }
            }
        });
        return file?.TryGetLocalPath();
    }
}
