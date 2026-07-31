using System.Threading.Tasks;
using Avalonia.Controls;
using Avalonia.Platform.Storage;
using RemoteStuff.ViewModels;

namespace RemoteStuff.Views;

public partial class GitSyncWindow : Window
{
    public GitSyncWindow()
    {
        InitializeComponent();
        DataContextChanged += (_, _) =>
        {
            if (DataContext is GitSyncViewModel vm)
                vm.PickFolderAsync = PickFolderAsync;
        };
    }

    /// <summary>Show a native folder picker; returns the chosen local path or null.</summary>
    private async Task<string?> PickFolderAsync()
    {
        var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions
        {
            Title = "Choose Local Working Copy Folder",
            AllowMultiple = false
        });
        return folders.Count > 0 ? folders[0].TryGetLocalPath() : null;
    }
}
