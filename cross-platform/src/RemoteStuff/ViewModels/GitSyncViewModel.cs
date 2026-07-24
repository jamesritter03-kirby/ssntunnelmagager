using System;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Services;

namespace RemoteStuff.ViewModels;

/// <summary>
/// Backs the "Sync Profiles with Git" window. Wraps a <see cref="GitProfileSync"/> service:
/// the user configures a remote + branch, then Pulls (import) or Pushes (share) their
/// profiles. After a successful Pull the supplied callback reloads the app's profiles.
/// </summary>
public sealed partial class GitSyncViewModel : ObservableObject
{
    private readonly GitProfileSync _sync;
    private readonly Action _onProfilesReplaced;

    [ObservableProperty] private string _remoteUrl = "";
    [ObservableProperty] private string _branch = "main";
    [ObservableProperty] private string _commitMessage = "";
    [ObservableProperty] private string _log = "";
    [ObservableProperty] private bool _isBusy;

    public string RepoPath => _sync.RepoDir;

    public GitSyncViewModel(GitProfileSync sync, Action onProfilesReplaced)
    {
        _sync = sync;
        _onProfilesReplaced = onProfilesReplaced;
        RemoteUrl = sync.Config.RemoteUrl;
        Branch = sync.Config.Branch;
    }

    private bool CanRun => !IsBusy;

    private void SaveConfig() => _sync.SaveConfig(RemoteUrl, Branch);

    private async Task RunAsync(Func<Task<GitSyncResult>> op, bool reloadOnSuccess = false)
    {
        if (IsBusy) return;
        IsBusy = true;
        SaveConfig();
        try
        {
            var result = await op();
            Log = result.Log;
            if (result.Success && reloadOnSuccess)
                _onProfilesReplaced();
        }
        catch (Exception ex)
        {
            Log = "Unexpected error:\n" + ex;
        }
        finally
        {
            IsBusy = false;
        }
    }

    [RelayCommand(CanExecute = nameof(CanRun))]
    private Task InitOrClone() => RunAsync(() => _sync.InitOrCloneAsync());

    [RelayCommand(CanExecute = nameof(CanRun))]
    private Task Pull() => RunAsync(() => _sync.PullAsync(), reloadOnSuccess: true);

    [RelayCommand(CanExecute = nameof(CanRun))]
    private Task Push() => RunAsync(() => _sync.PushAsync(CommitMessage));

    [RelayCommand(CanExecute = nameof(CanRun))]
    private Task Status() => RunAsync(() => _sync.StatusAsync());

    partial void OnIsBusyChanged(bool value)
    {
        InitOrCloneCommand.NotifyCanExecuteChanged();
        PullCommand.NotifyCanExecuteChanged();
        PushCommand.NotifyCanExecuteChanged();
        StatusCommand.NotifyCanExecuteChanged();
    }
}
