using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using RemoteStuff.Models;

namespace RemoteStuff.Services;

/// <summary>Mounts a profile's remote home directory locally via <c>sshfs</c>
/// (FUSE), so an SFTP connection can be opened in the file manager and used by
/// any app as an ordinary folder. A cross-platform port of the macOS
/// <c>SFTPMounter</c>. The mount is an independent ssh connection, so it does not
/// depend on the interactive SFTP browser being connected.</summary>
public sealed class SftpMounter
{
    // A GUI app launched from the desktop inherits a minimal PATH, so probe the
    // usual Homebrew / system locations directly instead of relying on `which`.
    private static readonly string[] SearchDirs =
    {
        "/opt/homebrew/bin", "/usr/local/bin", "/opt/homebrew/sbin",
        "/usr/local/sbin", "/usr/bin", "/bin",
    };

    /// <summary>Path to an installed <c>sshfs</c>, or null if none is found.</summary>
    public static string? SshfsPath => Locate("sshfs");

    /// <summary>Whether a usable FUSE mount helper is installed.</summary>
    public static bool HelperInstalled => SshfsPath != null;

    private static string? Locate(string tool)
    {
        foreach (var dir in SearchDirs)
        {
            try
            {
                var path = Path.Combine(dir, tool);
                if (File.Exists(path)) return path;
            }
            catch { /* ignore */ }
        }
        return null;
    }

    /// <summary>The current mount point once mounted, else null.</summary>
    public string? MountPoint { get; private set; }

    /// <summary>Where a profile mounts: <c>~/mnt/&lt;name&gt;</c>.</summary>
    public static string MountPointFor(SshProfile profile)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var name = Sanitize(string.IsNullOrWhiteSpace(profile.Name) ? profile.Host : profile.Name);
        return Path.Combine(home, "mnt", string.IsNullOrEmpty(name) ? "remote" : name);
    }

    private static string Sanitize(string name)
    {
        foreach (var c in Path.GetInvalidFileNameChars()) name = name.Replace(c, '-');
        return name.Trim();
    }

    /// <summary>Mount the profile's remote home directory. Returns success and,
    /// on success, the mount path; on failure, a friendly message.</summary>
    public async Task<(bool ok, string message)> MountAsync(SshProfile profile, string? password)
    {
        var sshfs = SshfsPath;
        if (sshfs == null) return (false, "No FUSE mount helper (sshfs) is installed.");

        var point = MountPointFor(profile);
        try { Directory.CreateDirectory(point); }
        catch (Exception ex) { return (false, "Couldn't create mount point: " + ex.Message); }

        var args = BuildArguments(profile, point, usePasswordStdin: !string.IsNullOrEmpty(password));

        return await Task.Run(() =>
        {
            try
            {
                var psi = new ProcessStartInfo(sshfs)
                {
                    UseShellExecute = false,
                    RedirectStandardInput = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true,
                };
                foreach (var a in args) psi.ArgumentList.Add(a);
                // sshfs shells out to `ssh` and FUSE helpers — make sure the usual
                // tool dirs are on PATH.
                const string toolDirs = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
                psi.Environment["PATH"] = toolDirs + ":" + (Environment.GetEnvironmentVariable("PATH") ?? "");

                using var proc = Process.Start(psi);
                if (proc == null) return (false, "Failed to launch sshfs.");
                if (!string.IsNullOrEmpty(password))
                {
                    proc.StandardInput.Write(password + "\n");
                    proc.StandardInput.Flush();
                }
                proc.StandardInput.Close();
                var err = proc.StandardError.ReadToEnd().Trim();
                proc.WaitForExit();
                // sshfs daemonizes once the mount is established, so exit 0 = success.
                if (proc.ExitCode == 0) { MountPoint = point; return (true, point); }
                TryRemoveDir(point);
                return (false, FriendlyError(string.IsNullOrEmpty(err)
                    ? $"sshfs exited with status {proc.ExitCode}." : err));
            }
            catch (Exception ex)
            {
                TryRemoveDir(point);
                return (false, ex.Message);
            }
        });
    }

    /// <summary>Unmount and clean up the mount-point directory.</summary>
    public async Task UnmountAsync()
    {
        var point = MountPoint;
        if (string.IsNullOrEmpty(point)) return;
        MountPoint = null;
        await Task.Run(() =>
        {
            // `umount` handles the common case; `diskutil unmount force` is the
            // macOS fallback for a busy fuse-t volume (harmless/absent on Linux).
            if (Run("/sbin/umount", point) != 0 &&
                Run("/usr/bin/fusermount", "-u", point) != 0)
                Run("/usr/sbin/diskutil", "unmount", "force", point);
            TryRemoveDir(point);
        });
    }

    private static void TryRemoveDir(string dir)
    {
        try { if (Directory.Exists(dir)) Directory.Delete(dir); } catch { /* ignore */ }
    }

    private static int Run(string launchPath, params string[] args)
    {
        try
        {
            if (!File.Exists(launchPath)) return -1;
            var psi = new ProcessStartInfo(launchPath)
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };
            foreach (var a in args) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi);
            if (p == null) return -1;
            p.WaitForExit();
            return p.ExitCode;
        }
        catch { return -1; }
    }

    /// <summary>Open the mount point in the platform file manager.</summary>
    public void Reveal()
    {
        if (string.IsNullOrEmpty(MountPoint)) return;
        try
        {
            var opener = RuntimeInformation.IsOSPlatform(OSPlatform.OSX) ? "open" : "xdg-open";
            Process.Start(new ProcessStartInfo(opener, $"\"{MountPoint}\"") { UseShellExecute = false });
        }
        catch { /* best-effort */ }
    }

    /// <summary>Build the <c>sshfs</c> argument list. The remote path is left empty
    /// (<c>host:</c>) so it mounts the remote home directory.</summary>
    internal static List<string> BuildArguments(SshProfile profile, string mountPoint, bool usePasswordStdin)
    {
        var host = (profile.Host ?? "").Trim();
        var user = (profile.Username ?? "").Trim();
        var dest = (user.Length == 0 ? host : $"{user}@{host}") + ":";
        var args = new List<string> { dest, mountPoint };

        if (int.TryParse((profile.Port ?? "").Trim(), out var port) && port != 22)
            args.AddRange(new[] { "-o", $"Port={port}" });
        var identity = (profile.IdentityFile ?? "").Trim();
        if (identity.Length > 0)
            args.AddRange(new[] { "-o", $"IdentityFile={SshCommandBuilder.ExpandPath(identity)}" });
        var jump = (profile.JumpHost ?? "").Trim();
        if (jump.Length > 0)
            args.AddRange(new[] { "-o", $"ProxyJump={jump}" });
        if (profile.Compression) args.AddRange(new[] { "-o", "Compression=yes" });
        if (usePasswordStdin) args.AddRange(new[] { "-o", "password_stdin" });

        // Reuse the already-trusted known_hosts (accept a new host automatically),
        // keep the link alive, auto-reconnect, and give a friendly volume name.
        args.AddRange(new[]
        {
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "reconnect",
            "-o", $"volname={(string.IsNullOrWhiteSpace(profile.Name) ? host : profile.Name)}",
        });
        return args;
    }

    private static string FriendlyError(string raw)
    {
        var lower = raw.ToLowerInvariant();
        if (lower.Contains("no fuse") || lower.Contains("fuse device not found") ||
            (lower.Contains("fuse") && lower.Contains("load")))
            return "The FUSE helper isn't fully set up. Finish installing sshfs (with macFUSE or fuse-t) " +
                   "and allow it in your system's privacy/security settings, then try again.\n\n" + raw;
        if (lower.Contains("permission denied") || lower.Contains("authentication"))
            return "Authentication failed. Check the profile's credentials, then try again.\n\n" + raw;
        if (lower.Contains("not a directory") || lower.Contains("mountpoint"))
            return "The mount point couldn't be prepared. Make sure ~/mnt is writable, then try again.\n\n" + raw;
        return string.IsNullOrEmpty(raw) ? "The mount failed for an unknown reason." : raw;
    }
}
