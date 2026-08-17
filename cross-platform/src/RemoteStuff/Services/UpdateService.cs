using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Velopack;
using Velopack.Logging;
using Velopack.Sources;

namespace RemoteStuff.Services;

/// <summary>
/// Cross-platform in-app updater (Windows / macOS / Linux) backed by Velopack and
/// GitHub Releases. Update packages are published to the repo below on the
/// <c>desktop-updates</c> release, one Velopack channel per runtime.
///
/// When the app is not a real Velopack install — e.g. running from bin/Debug during
/// development — every operation no-ops gracefully so update checks never throw.
///
/// Every check / download / apply is appended to <see cref="LogPath"/> so a stuck
/// update (installed but the version never advances) can be diagnosed after the fact.
/// </summary>
public sealed class UpdateService
{
    private const string RepoUrl = "https://github.com/jamesritter03-kirby/ssntunnelmagager";
    private const string ReleaseTag = "desktop-updates";

    private readonly GithubSource _source;
    private readonly UpdateManager _mgr;

    public UpdateService()
    {
        _source = new GithubSource(RepoUrl, accessToken: null, prerelease: false);
        _mgr = new UpdateManager(_source);
    }

    /// <summary>The public GitHub releases page, where every published build is listed.</summary>
    public static string ReleasesPageUrl => $"{RepoUrl}/releases";

    /// <summary>True only when running as an installed Velopack app.</summary>
    public bool IsInstalled => _mgr.IsInstalled;

    /// <summary>The running app version reported by Velopack, or null if unknown.</summary>
    public string? CurrentVersion => _mgr.CurrentVersion?.ToString();

    /// <summary>Version compiled into the running assembly. When this differs from
    /// <see cref="CurrentVersion"/> after an update, the folder swap never finalized —
    /// the "installed but still runs the old version" loop — and a reinstall is needed.</summary>
    public static string RunningVersion { get; } = ResolveRunningVersion();

    /// <summary>
    /// Check GitHub for a newer release. Returns the pending update, or null if the
    /// app is already up to date, isn't an installed build, or the check failed.
    /// </summary>
    public async Task<UpdateInfo?> CheckAsync()
    {
        if (!_mgr.IsInstalled)
        {
            Log("check: skipped — not an installed build");
            return null;
        }
        try
        {
            var info = await _mgr.CheckForUpdatesAsync();
            Log(info is null
                ? $"check: up to date (velopack={CurrentVersion}, running={RunningVersion})"
                : $"check: update {info.TargetFullRelease.Version} available " +
                  $"(velopack={CurrentVersion}, running={RunningVersion})");
            if (CurrentVersion is { } cv && cv != RunningVersion)
                Log($"check: WARNING velopack={cv} != running assembly {RunningVersion} — " +
                    "a previous update did not finalize; a clean reinstall is recommended");
            return info;
        }
        catch (Exception ex)
        {
            // Network errors, missing feed for this channel, etc. — treat as "no update".
            Log("check: failed — " + ex.Message);
            return null;
        }
    }

    /// <summary>Download the pending update, then apply it and restart the app.</summary>
    public async Task DownloadAndApplyAsync(UpdateInfo info)
    {
        var target = info.TargetFullRelease.Version.ToString();
        Log($"apply: downloading -> {target} (from velopack={CurrentVersion}, running={RunningVersion})");
        await _mgr.DownloadUpdatesAsync(info);
        Log($"apply: download complete -> {target}; applying and restarting");
        _mgr.ApplyUpdatesAndRestart(info); // exits the process; nothing after this runs
    }

    /// <summary>The Velopack channel this build installs from — one per runtime, named after
    /// the RID (matches velopack.sh <c>CHANNEL=$RID</c>), e.g. win-x64 / osx-arm64.</summary>
    private static string Channel()
    {
        var os = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "win"
               : RuntimeInformation.IsOSPlatform(OSPlatform.OSX) ? "osx"
               : "linux";
        var arch = RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "arm64" : "x64";
        return $"{os}-{arch}";
    }

    /// <summary>Every full release available on this platform's update feed, newest first,
    /// excluding the running one — the versions the user can roll back to (or forward to).
    /// Empty when not an installed build or the feed can't be read.</summary>
    public async Task<IReadOnlyList<string>> GetAvailableVersionsAsync()
    {
        if (!_mgr.IsInstalled) return Array.Empty<string>();
        try
        {
            var feed = await _source.GetReleaseFeed(NullVelopackLogger.Instance, _mgr.AppId, Channel());
            var current = _mgr.CurrentVersion?.ToString();
            var versions = feed.Assets
                .Where(a => a.Type == VelopackAssetType.Full)
                .OrderByDescending(a => a.Version)
                .Select(a => a.Version.ToString())
                .Distinct()
                .Where(v => v != current)
                .ToList();
            Log($"versions: {versions.Count} available on channel {Channel()}");
            return versions;
        }
        catch (Exception ex)
        {
            Log("versions: failed — " + ex.Message);
            return Array.Empty<string>();
        }
    }

    /// <summary>Install a specific published version in place (a downgrade or re-install),
    /// then restart the app. Returns false without restarting when it can't be done
    /// (dev build, version not on the feed, or download failed).</summary>
    public async Task<bool> InstallVersionAsync(string version)
    {
        if (!_mgr.IsInstalled)
        {
            Log($"install {version}: skipped — not an installed build");
            return false;
        }
        try
        {
            var feed = await _source.GetReleaseFeed(NullVelopackLogger.Instance, _mgr.AppId, Channel());
            var asset = feed.Assets.FirstOrDefault(
                a => a.Type == VelopackAssetType.Full && a.Version.ToString() == version);
            if (asset is null)
            {
                Log($"install {version}: not found on feed");
                return false;
            }
            var isDowngrade = _mgr.CurrentVersion is { } cur && asset.Version < cur;
            // A dedicated manager that permits going backwards; the default one refuses.
            var mgr = new UpdateManager(_source, new UpdateOptions { AllowVersionDowngrade = true });
            var info = new UpdateInfo(asset, isDowngrade);
            Log($"install {version}: downloading (downgrade={isDowngrade}, from {CurrentVersion})");
            await mgr.DownloadUpdatesAsync(info);
            Log($"install {version}: applying and restarting");
            mgr.ApplyUpdatesAndRestart(info); // exits the process; nothing after this runs
            return true;
        }
        catch (Exception ex)
        {
            Log($"install {version}: failed — " + ex.Message);
            return false;
        }
    }

    /// <summary>Download the current platform's full installer to a temp file for a
    /// clean reinstall / repair, returning its path (or null if unsupported/failed).</summary>
    public async Task<string?> DownloadInstallerAsync()
    {
        var asset = InstallerAsset();
        if (asset is null)
        {
            Log("repair: no installer asset for this platform");
            return null;
        }
        var url = $"{RepoUrl}/releases/download/{ReleaseTag}/{asset}";
        var dest = Path.Combine(Path.GetTempPath(), asset);
        try
        {
            Log($"repair: downloading {url}");
            using var http = new HttpClient();
            using var resp = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
            resp.EnsureSuccessStatusCode();
            await using (var fs = File.Create(dest))
                await resp.Content.CopyToAsync(fs);
            Log($"repair: saved installer to {dest}");
            return dest;
        }
        catch (Exception ex)
        {
            Log("repair: download failed — " + ex.Message);
            return null;
        }
    }

    /// <summary>The release asset name that reinstalls this platform's build.</summary>
    private static string? InstallerAsset()
    {
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            return "RemoteStuff-win-x64-Setup.exe";
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
            return "RemoteStuff-linux-x64.AppImage";
        if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
            return RuntimeInformation.OSArchitecture == Architecture.Arm64
                ? "RemoteStuff-osx-arm64-Setup.pkg"
                : "RemoteStuff-osx-x64-Setup.pkg";
        return null;
    }

    private static string ResolveRunningVersion()
    {
        var asm = Assembly.GetExecutingAssembly();
        var info = asm.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
                   ?? asm.GetName().Version?.ToString() ?? "?";
        var plus = info.IndexOf('+');
        return plus >= 0 ? info[..plus] : info;
    }

    /// <summary><c>~/…/RemoteStuff/update.log</c> — a sibling of <c>profiles.json</c>.</summary>
    public static string LogPath
    {
        get
        {
            var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            if (string.IsNullOrEmpty(baseDir))
                baseDir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
            return Path.Combine(baseDir, "RemoteStuff", "update.log");
        }
    }

    /// <summary>Append a timestamped line to the update log; never throws.</summary>
    public static void Log(string message)
    {
        try
        {
            var path = LogPath;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.AppendAllText(path, $"{DateTimeOffset.Now:O}  {message}\n");
        }
        catch { /* logging must never itself crash the app */ }
    }
}
