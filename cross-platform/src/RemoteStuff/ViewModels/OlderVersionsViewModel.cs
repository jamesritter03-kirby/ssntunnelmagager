using System;
using System.Collections.ObjectModel;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Services;

namespace RemoteStuff.ViewModels;

/// <summary>Backs the "Install an Older Version" window: lists every build published to
/// this platform's update feed and lets the user roll back to (or reinstall) any of them
/// in place via Velopack. Mirrors the macOS app's <c>OlderVersionsView</c>, but installs
/// the chosen version directly instead of just opening a browser download.</summary>
public sealed partial class OlderVersionsViewModel : ObservableObject
{
    private readonly UpdateService _updates;
    private readonly Func<Task> _checkLatest;
    private readonly Action<string> _setStatus;

    /// <summary>Selectable published versions, newest first, excluding the running one.</summary>
    public ObservableCollection<string> Versions { get; } = new();

    [ObservableProperty] private bool _isLoading = true;

    /// <summary>The running app version, shown in the header.</summary>
    public string CurrentVersion => _updates.CurrentVersion ?? UpdateService.RunningVersion;

    /// <summary>True only for a real installed build; version install needs Velopack.</summary>
    public bool IsInstalled => _updates.IsInstalled;

    public bool HasVersions => Versions.Count > 0;

    /// <summary>Shown in place of the list when there's nothing to install.</summary>
    public string EmptyMessage => !IsInstalled
        ? "Version rollback is only available in the installed app. Use the button below to browse all releases on GitHub."
        : IsLoading ? "Loading available versions…"
        : "No other versions are available on the update feed right now.";

    public OlderVersionsViewModel(UpdateService updates, Func<Task> checkLatest, Action<string> setStatus)
    {
        _updates = updates;
        _checkLatest = checkLatest;
        _setStatus = setStatus;
        _ = LoadAsync();
    }

    private async Task LoadAsync()
    {
        IsLoading = true;
        OnPropertyChanged(nameof(EmptyMessage));
        var versions = await _updates.GetAvailableVersionsAsync();
        Versions.Clear();
        foreach (var v in versions) Versions.Add(v);
        IsLoading = false;
        OnPropertyChanged(nameof(HasVersions));
        OnPropertyChanged(nameof(EmptyMessage));
    }

    [RelayCommand]
    private Task Refresh() => LoadAsync();

    /// <summary>Run the normal "check for the latest version" flow from the Tools menu.</summary>
    [RelayCommand]
    private Task CheckLatest() => _checkLatest();

    /// <summary>Open the GitHub releases page so the user can browse every build.</summary>
    [RelayCommand]
    private void OpenReleasesPage() => SystemOpen.Open(UpdateService.ReleasesPageUrl);

    /// <summary>Confirm, then download the chosen version and restart into it.</summary>
    [RelayCommand]
    private async Task InstallVersion(string? version)
    {
        if (string.IsNullOrEmpty(version)) return;
        var confirm = await DialogService.ConfirmAsync(
            "Install version " + version + "?",
            $"This downloads Remote Stuff CP {version} and installs it in place of your current " +
            $"build ({CurrentVersion}). The app will restart to finish.",
            "Install & Restart", "Cancel");
        if (!confirm) return;

        _setStatus($"Downloading version {version}…");
        var ok = await _updates.InstallVersionAsync(version); // restarts on success
        if (!ok)
            _setStatus($"Couldn't install version {version} — see the update log for details.");
    }
}
