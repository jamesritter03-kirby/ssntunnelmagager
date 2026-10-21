using System.Threading.Tasks;
using Avalonia.Controls;
using Avalonia.Platform.Storage;
using RemoteStuff.Services;
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
            {
                vm.PickFolderAsync = PickFolderAsync;
                vm.ResolveConflictAsync = ResolveConflictAsync;
            }
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

    /// <summary>Ask which side of a Pull merge conflict to keep. Owned by this window so the
    /// chooser stacks on top of the modal sync dialog.</summary>
    private async Task<GitConflictResolution> ResolveConflictAsync()
    {
        var idx = await DialogService.ChooseAsync(this, "Merge conflict",
            "The remote and your local copy both changed the same profiles or workspaces. " +
            "Which version would you like to keep?",
            new[] { "Keep Remote Version", "Keep My Version", "Cancel" });
        return idx switch
        {
            0 => GitConflictResolution.KeepRemote,
            1 => GitConflictResolution.KeepLocal,
            _ => GitConflictResolution.None
        };
    }
}
