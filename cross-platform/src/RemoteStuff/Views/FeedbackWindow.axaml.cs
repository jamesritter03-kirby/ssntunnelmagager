using System.IO;
using System.Threading.Tasks;
using Avalonia.Controls;
using Avalonia.Platform.Storage;
using RemoteStuff.ViewModels;

namespace RemoteStuff.Views;

public partial class FeedbackWindow : Window
{
    public FeedbackWindow()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
    }

    private FeedbackViewModel? _vm;

    private void OnDataContextChanged(object? sender, System.EventArgs e)
    {
        if (_vm is not null) _vm.ExportRequested -= SaveExport;
        _vm = DataContext as FeedbackViewModel;
        if (_vm is not null) _vm.ExportRequested += SaveExport;
    }

    private async Task SaveExport(string suggestedName, string content)
    {
        var ext = Path.GetExtension(suggestedName).TrimStart('.');
        var isJson = ext.Equals("json", System.StringComparison.OrdinalIgnoreCase);
        var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Export feedback",
            SuggestedFileName = suggestedName,
            DefaultExtension = ext,
            FileTypeChoices = new[]
            {
                isJson
                    ? new FilePickerFileType("JSON") { Patterns = new[] { "*.json" } }
                    : new FilePickerFileType("Markdown") { Patterns = new[] { "*.md" } }
            }
        });
        if (file?.TryGetLocalPath() is { } path)
            await File.WriteAllTextAsync(path, content);
    }
}
