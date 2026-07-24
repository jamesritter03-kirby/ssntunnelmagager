using System;
using System.Threading.Tasks;
using Velopack;
using Velopack.Sources;

namespace RemoteStuff.Services;

/// <summary>
/// Cross-platform in-app updater (Windows / macOS / Linux) backed by Velopack and
/// GitHub Releases. Update packages are published to the repo below on the
/// <c>desktop-updates</c> release, one Velopack channel per runtime.
///
/// When the app is not a real Velopack install — e.g. running from bin/Debug during
/// development — every operation no-ops gracefully so update checks never throw.
/// </summary>
public sealed class UpdateService
{
    private const string RepoUrl = "https://github.com/jamesritter03-kirby/ssntunnelmagager";

    private readonly UpdateManager _mgr;

    public UpdateService()
    {
        _mgr = new UpdateManager(new GithubSource(RepoUrl, accessToken: null, prerelease: false));
    }

    /// <summary>True only when running as an installed Velopack app.</summary>
    public bool IsInstalled => _mgr.IsInstalled;

    /// <summary>The running app version reported by Velopack, or null if unknown.</summary>
    public string? CurrentVersion => _mgr.CurrentVersion?.ToString();

    /// <summary>
    /// Check GitHub for a newer release. Returns the pending update, or null if the
    /// app is already up to date, isn't an installed build, or the check failed.
    /// </summary>
    public async Task<UpdateInfo?> CheckAsync()
    {
        if (!_mgr.IsInstalled) return null;
        try
        {
            return await _mgr.CheckForUpdatesAsync();
        }
        catch (Exception)
        {
            // Network errors, missing feed for this channel, etc. — treat as "no update".
            return null;
        }
    }

    /// <summary>Download the pending update, then apply it and restart the app.</summary>
    public async Task DownloadAndApplyAsync(UpdateInfo info)
    {
        await _mgr.DownloadUpdatesAsync(info);
        _mgr.ApplyUpdatesAndRestart(info);
    }
}
