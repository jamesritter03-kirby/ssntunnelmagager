using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace RemoteStuff.Services;

/// <summary>The outcome of a Git sync operation, with a human-readable log.</summary>
public sealed record GitSyncResult(bool Success, string Log);

/// <summary>Persisted Git-sync configuration (remote URL + branch).</summary>
public sealed class GitSyncConfig
{
    public string RemoteUrl { get; set; } = "";
    public string Branch { get; set; } = "main";
}

/// <summary>
/// Syncs the user's <c>profiles.json</c> with a Git repository so profiles can be shared
/// between machines. A local working copy is kept under the app-data dir; Pull copies the
/// repo's profiles back into the store, Push commits the store's profiles and (if a remote
/// is set) pushes them. Uses the system <c>git</c> CLI via a non-shell process so user input
/// (the remote URL) can never be interpreted as a command.
/// </summary>
public sealed class GitProfileSync
{
    private const string ProfilesFileName = "profiles.json";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };

    private readonly string _profilesPath;
    private readonly string _repoDir;
    private readonly string _configPath;

    public GitSyncConfig Config { get; private set; } = new();

    /// <summary>Absolute path of the local Git working copy.</summary>
    public string RepoDir => _repoDir;

    public GitProfileSync(string profilesPath)
    {
        _profilesPath = profilesPath;
        var appDir = Path.GetDirectoryName(profilesPath) ?? Directory.GetCurrentDirectory();
        _repoDir = Path.Combine(appDir, "profiles-repo");
        _configPath = Path.Combine(appDir, "git-sync.json");
        LoadConfig();
    }

    private void LoadConfig()
    {
        try
        {
            if (File.Exists(_configPath))
            {
                var loaded = JsonSerializer.Deserialize<GitSyncConfig>(File.ReadAllText(_configPath), JsonOptions);
                if (loaded != null) Config = loaded;
            }
        }
        catch { /* keep defaults */ }

        if (string.IsNullOrWhiteSpace(Config.Branch)) Config.Branch = "main";
    }

    public void SaveConfig(string remoteUrl, string branch)
    {
        Config.RemoteUrl = (remoteUrl ?? "").Trim();
        Config.Branch = string.IsNullOrWhiteSpace(branch) ? "main" : branch.Trim();
        try
        {
            var tmp = _configPath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(Config, JsonOptions));
            File.Move(tmp, _configPath, overwrite: true);
        }
        catch { /* best-effort */ }
    }

    private bool RepoInitialized => Directory.Exists(Path.Combine(_repoDir, ".git"));

    /// <summary>Clone the configured remote (or <c>git init</c> a fresh local repo).</summary>
    public async Task<GitSyncResult> InitOrCloneAsync()
    {
        var log = new StringBuilder();
        if (!await GitAvailableAsync(log))
            return new GitSyncResult(false, log.ToString());

        if (RepoInitialized)
        {
            log.AppendLine("Repository already initialised at:");
            log.AppendLine("  " + _repoDir);
            return new GitSyncResult(true, log.ToString());
        }

        Directory.CreateDirectory(_repoDir);

        if (!string.IsNullOrWhiteSpace(Config.RemoteUrl))
        {
            // Clone into a temp dir then move contents in, since git clone needs an empty target.
            var parent = Path.GetDirectoryName(_repoDir)!;
            var tmpClone = Path.Combine(parent, "profiles-repo.clone-" + Guid.NewGuid().ToString("N"));
            var (code, output) = await RunGitAsync(parent, log, "clone", "--branch", Config.Branch, Config.RemoteUrl, tmpClone);
            if (code != 0)
            {
                // The branch may not exist yet on a brand-new remote — clone default branch.
                log.AppendLine("Retrying clone without an explicit branch…");
                (code, output) = await RunGitAsync(parent, log, "clone", Config.RemoteUrl, tmpClone);
            }
            if (code != 0)
            {
                TryDelete(tmpClone);
                return new GitSyncResult(false, log.ToString());
            }

            TryDelete(_repoDir);
            Directory.Move(tmpClone, _repoDir);
            await RunGitAsync(_repoDir, log, "checkout", "-B", Config.Branch);
            log.AppendLine("Cloned into local working copy.");
            return new GitSyncResult(true, log.ToString());
        }

        // No remote: start a local-only repository.
        await RunGitAsync(_repoDir, log, "init");
        await RunGitAsync(_repoDir, log, "checkout", "-B", Config.Branch);
        log.AppendLine("Initialised a local Git repository (no remote configured).");
        return new GitSyncResult(true, log.ToString());
    }

    /// <summary>Pull the latest profiles from the repo and copy them into the live store.</summary>
    public async Task<GitSyncResult> PullAsync()
    {
        var log = new StringBuilder();
        if (!await GitAvailableAsync(log))
            return new GitSyncResult(false, log.ToString());

        if (!RepoInitialized)
        {
            var init = await InitOrCloneAsync();
            log.Append(init.Log);
            if (!init.Success) return new GitSyncResult(false, log.ToString());
        }

        if (!string.IsNullOrWhiteSpace(Config.RemoteUrl))
        {
            await EnsureRemoteAsync(log);
            var (code, _) = await RunGitAsync(_repoDir, log, "pull", "--no-rebase", "origin", Config.Branch);
            if (code != 0) return new GitSyncResult(false, log.ToString());
        }

        var repoProfiles = Path.Combine(_repoDir, ProfilesFileName);
        if (!File.Exists(repoProfiles))
        {
            log.AppendLine("No profiles.json in the repo yet — nothing to import. Push first.");
            return new GitSyncResult(true, log.ToString());
        }

        try
        {
            File.Copy(repoProfiles, _profilesPath, overwrite: true);
            log.AppendLine("Imported profiles.json from the repository into the app.");
            return new GitSyncResult(true, log.ToString());
        }
        catch (Exception ex)
        {
            log.AppendLine("Failed to copy profiles into the app: " + ex.Message);
            return new GitSyncResult(false, log.ToString());
        }
    }

    /// <summary>Copy the live profiles into the repo, commit, and push (if a remote is set).</summary>
    public async Task<GitSyncResult> PushAsync(string? commitMessage = null)
    {
        var log = new StringBuilder();
        if (!await GitAvailableAsync(log))
            return new GitSyncResult(false, log.ToString());

        if (!RepoInitialized)
        {
            var init = await InitOrCloneAsync();
            log.Append(init.Log);
            if (!init.Success) return new GitSyncResult(false, log.ToString());
        }

        if (!File.Exists(_profilesPath))
        {
            log.AppendLine("No local profiles.json to push.");
            return new GitSyncResult(false, log.ToString());
        }

        try
        {
            File.Copy(_profilesPath, Path.Combine(_repoDir, ProfilesFileName), overwrite: true);
        }
        catch (Exception ex)
        {
            log.AppendLine("Failed to stage profiles into the repo: " + ex.Message);
            return new GitSyncResult(false, log.ToString());
        }

        await RunGitAsync(_repoDir, log, "add", ProfilesFileName);

        // Nothing staged => no commit needed.
        var (statusCode, status) = await RunGitAsync(_repoDir, log, "status", "--porcelain");
        if (statusCode == 0 && string.IsNullOrWhiteSpace(status))
        {
            log.AppendLine("Profiles already up to date — nothing to commit.");
        }
        else
        {
            var msg = string.IsNullOrWhiteSpace(commitMessage)
                ? $"Update profiles {DateTime.Now:yyyy-MM-dd HH:mm}"
                : commitMessage!.Trim();
            var (commitCode, _) = await RunGitAsync(_repoDir, log, "commit", "-m", msg);
            if (commitCode != 0) return new GitSyncResult(false, log.ToString());
        }

        if (!string.IsNullOrWhiteSpace(Config.RemoteUrl))
        {
            await EnsureRemoteAsync(log);
            var (pushCode, _) = await RunGitAsync(_repoDir, log, "push", "-u", "origin", Config.Branch);
            if (pushCode != 0) return new GitSyncResult(false, log.ToString());
            log.AppendLine("Pushed profiles to the remote.");
        }
        else
        {
            log.AppendLine("Committed locally (no remote configured to push to).");
        }

        return new GitSyncResult(true, log.ToString());
    }

    /// <summary>Show the working-copy status.</summary>
    public async Task<GitSyncResult> StatusAsync()
    {
        var log = new StringBuilder();
        if (!await GitAvailableAsync(log))
            return new GitSyncResult(false, log.ToString());
        if (!RepoInitialized)
        {
            log.AppendLine("No local repository yet. Use “Init / Clone”.");
            return new GitSyncResult(true, log.ToString());
        }
        await RunGitAsync(_repoDir, log, "status", "--short", "--branch");
        return new GitSyncResult(true, log.ToString());
    }

    private async Task EnsureRemoteAsync(StringBuilder log)
    {
        var (code, url) = await RunGitAsync(_repoDir, log, quiet: true, "remote", "get-url", "origin");
        if (code != 0)
            await RunGitAsync(_repoDir, log, "remote", "add", "origin", Config.RemoteUrl);
        else if (url.Trim() != Config.RemoteUrl)
            await RunGitAsync(_repoDir, log, "remote", "set-url", "origin", Config.RemoteUrl);
    }

    private async Task<bool> GitAvailableAsync(StringBuilder log)
    {
        try
        {
            var (code, _) = await RunGitAsync(Directory.GetCurrentDirectory(), log, quiet: true, "--version");
            if (code == 0) return true;
        }
        catch { /* fall through */ }
        log.AppendLine("Git is not available. Install the Xcode Command Line Tools or Git and try again.");
        return false;
    }

    private static Task<(int Code, string Output)> RunGitAsync(string workingDir, StringBuilder log, params string[] args)
        => RunGitAsync(workingDir, log, quiet: false, args);

    private static async Task<(int Code, string Output)> RunGitAsync(
        string workingDir, StringBuilder log, bool quiet, params string[] args)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "git",
            WorkingDirectory = workingDir,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        // Never let git block on an interactive credential prompt.
        psi.Environment["GIT_TERMINAL_PROMPT"] = "0";

        if (!quiet) log.AppendLine("$ git " + string.Join(' ', args));

        using var proc = new Process { StartInfo = psi };
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        proc.OutputDataReceived += (_, e) => { if (e.Data != null) stdout.AppendLine(e.Data); };
        proc.ErrorDataReceived += (_, e) => { if (e.Data != null) stderr.AppendLine(e.Data); };

        try
        {
            proc.Start();
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();
            await proc.WaitForExitAsync();
        }
        catch (Exception ex)
        {
            log.AppendLine("  error: " + ex.Message);
            return (-1, "");
        }

        if (!quiet)
        {
            if (stdout.Length > 0) log.Append(stdout);
            if (stderr.Length > 0) log.Append(stderr);
        }
        return (proc.ExitCode, stdout.ToString());
    }

    private static void TryDelete(string dir)
    {
        try { if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true); }
        catch { /* ignore */ }
    }
}
