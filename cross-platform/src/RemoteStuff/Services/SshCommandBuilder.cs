using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using RemoteStuff.Models;

namespace RemoteStuff.Services;

/// <summary>
/// Builds the <c>ssh</c> argument list (and a human-readable preview) for a profile.
/// A faithful cross-platform port of the original Swift <c>SSHCommandBuilder</c>.
/// </summary>
public static class SshCommandBuilder
{
    /// <summary>Expand a leading <c>~</c> to the user's home directory.</summary>
    public static string ExpandPath(string path)
    {
        if (string.IsNullOrEmpty(path)) return path;
        if (path == "~")
            return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (path.StartsWith("~/", StringComparison.Ordinal) || path.StartsWith("~\\", StringComparison.Ordinal))
        {
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            return home + path[1..];
        }
        return path;
    }

    /// <summary>
    /// Locate the OpenSSH <c>ssh</c> client executable, returning its full path or
    /// <c>null</c> if none is found. The interactive terminal shells out to this
    /// binary (unlike SFTP, which uses the bundled SSH.NET library), so a machine
    /// missing the Windows "OpenSSH Client" optional feature can SFTP but not open
    /// an SSH terminal. Checking the canonical System32 location — not just PATH —
    /// covers installs that didn't refresh the app's PATH.
    /// </summary>
    public static string? FindSshExecutable()
    {
        if (OperatingSystem.IsWindows())
        {
            var candidates = new List<string>();
            var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
            if (!string.IsNullOrEmpty(system))
                candidates.Add(Path.Combine(system, "OpenSSH", "ssh.exe"));
            var pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            if (!string.IsNullOrEmpty(pf))
            {
                candidates.Add(Path.Combine(pf, "OpenSSH", "ssh.exe"));
                candidates.Add(Path.Combine(pf, "Git", "usr", "bin", "ssh.exe"));
            }
            foreach (var c in candidates)
                if (File.Exists(c)) return c;
            return SearchPath("ssh.exe");
        }

        foreach (var c in new[] { "/usr/bin/ssh", "/usr/local/bin/ssh", "/opt/homebrew/bin/ssh" })
            if (File.Exists(c)) return c;
        return SearchPath("ssh");
    }

    /// <summary>Find an executable by scanning the <c>PATH</c> environment variable.</summary>
    private static string? SearchPath(string exeName)
    {
        var path = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrEmpty(path)) return null;
        foreach (var dir in path.Split(Path.PathSeparator))
        {
            if (string.IsNullOrWhiteSpace(dir)) continue;
            try
            {
                var full = Path.Combine(dir.Trim(), exeName);
                if (File.Exists(full)) return full;
            }
            catch { /* skip malformed PATH entries */ }
        }
        return null;
    }

    /// <summary>Build the argument list passed to <c>ssh</c> for a profile.</summary>
    /// <param name="suppressPasswordAuth">When true (key set, no stored password), adds PasswordAuthentication=no so SSH won't fall back to prompting.</param>
    public static List<string> Arguments(SshProfile profile, string? controlPath = null, bool suppressPasswordAuth = false)
    {
        var args = new List<string>();

        var remoteCommand = profile.RemoteCommand.Trim();
        var hasRemoteCommand = remoteCommand.Length > 0;

        if (!profile.OpenShell && !hasRemoteCommand)
            args.Add("-N");
        if (profile.Compression)
            args.Add("-C");
        if (profile.Verbose)
            args.Add("-v");
        if (profile.ForwardAgent)
            args.Add("-A");
        if (profile.RequestTty && hasRemoteCommand)
            args.AddRange(new[] { "-t", "-t" });
        if (profile.KeepAlive)
            args.AddRange(new[] { "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3" });
        if (!string.IsNullOrEmpty(controlPath))
            args.AddRange(new[]
            {
                "-o", "ControlMaster=auto",
                "-o", $"ControlPath={controlPath}",
                "-o", "ControlPersist=no"
            });
        if (profile.AddKeysToAgent)
            args.AddRange(new[] { "-o", "AddKeysToAgent=yes" });
        if (profile.ConnectTimeout > 0)
            args.AddRange(new[] { "-o", $"ConnectTimeout={profile.ConnectTimeout}" });
        var hostKeyValue = profile.StrictHostKeyChecking.OptionValue();
        if (hostKeyValue != null)
            args.AddRange(new[] { "-o", $"StrictHostKeyChecking={hostKeyValue}" });
        foreach (var env in profile.Environment)
        {
            var token = env.SetEnvToken;
            if (token != null)
                args.AddRange(new[] { "-o", $"SetEnv={token}" });
        }
        if (profile.Forwards.Count > 0)
            args.AddRange(new[] { "-o", "ExitOnForwardFailure=yes" });

        if (int.TryParse(profile.Port.Trim(), out var port) && port != 22)
            args.AddRange(new[] { "-p", port.ToString() });

        var identity = profile.IdentityFile.Trim();
        if (identity.Length > 0)
        {
            // Use only this key; without IdentitiesOnly ssh may offer agent keys
            // first, hit MaxAuthTries, and fall back to a password prompt.
            args.AddRange(new[] { "-i", ExpandPath(identity), "-o", "IdentitiesOnly=yes" });
            if (suppressPasswordAuth)
                args.AddRange(new[] { "-o", "PasswordAuthentication=no" });
        }

        var jump = profile.JumpHost.Trim();
        if (jump.Length > 0)
            args.AddRange(new[] { "-J", jump });

        foreach (var forward in profile.Forwards)
        {
            var opt = ForwardOption(forward);
            if (opt is { } o)
                args.AddRange(new[] { o.Flag, o.Spec });
        }

        var extra = profile.ExtraOptions.Trim();
        if (extra.Length > 0)
            args.AddRange(extra.Split(new[] { ' ', '\n', '\t', '\r' }, StringSplitOptions.RemoveEmptyEntries));

        var host = profile.Host.Trim();
        var user = profile.Username.Trim();
        var dest = user.Length == 0 ? host : $"{user}@{host}";
        if (dest.Length > 0)
            args.Add(dest);

        if (hasRemoteCommand)
            args.Add(remoteCommand);

        return args;
    }

    /// <summary>A human-readable, copy-pasteable command preview.</summary>
    public static string CommandPreview(SshProfile profile)
        => profile.UseMosh
            ? string.Join(" ", new[] { "mosh" }.Concat(MoshArguments(profile)).Select(ShellQuote))
            : string.Join(" ", new[] { "ssh" }.Concat(Arguments(profile)).Select(ShellQuote));

    /// <summary>
    /// Build the argument list passed to <c>mosh</c>. Mosh drives its own ssh
    /// connection, so connection options are forwarded via <c>--ssh</c>; port
    /// forwards are not supported by mosh and are omitted.
    /// </summary>
    public static List<string> MoshArguments(SshProfile profile)
    {
        var sshOpts = new List<string> { "ssh" };

        if (int.TryParse(profile.Port.Trim(), out var port) && port != 22)
            sshOpts.AddRange(new[] { "-p", port.ToString() });

        var identity = profile.IdentityFile.Trim();
        if (identity.Length > 0)
            sshOpts.AddRange(new[] { "-i", ExpandPath(identity), "-o", "IdentitiesOnly=yes" });

        var jump = profile.JumpHost.Trim();
        if (jump.Length > 0)
            sshOpts.AddRange(new[] { "-J", jump });

        if (profile.Compression)
            sshOpts.Add("-C");
        if (profile.ForwardAgent)
            sshOpts.Add("-A");

        var hostKeyValue = profile.StrictHostKeyChecking.OptionValue();
        if (hostKeyValue != null)
            sshOpts.AddRange(new[] { "-o", $"StrictHostKeyChecking={hostKeyValue}" });

        var args = new List<string>
        {
            $"--ssh={string.Join(" ", sshOpts.Select(ShellQuote))}"
        };

        args.Add(Destination(profile));

        var remoteCommand = profile.RemoteCommand.Trim();
        if (remoteCommand.Length > 0)
        {
            args.Add("--");
            args.Add(remoteCommand);
        }

        return args;
    }

    /// <summary>The <c>[user@]host</c> destination for a profile.</summary>
    public static string Destination(SshProfile profile)
    {
        var host = profile.Host.Trim();
        var user = profile.Username.Trim();
        return user.Length == 0 ? host : $"{user}@{host}";
    }

    /// <summary>
    /// Build a minimal <c>ssh -N -L</c> argument list dedicated to tunnelling a VNC
    /// session: the profile's connection options plus a single local forward from
    /// <paramref name="localPort"/> to the remote host's <paramref name="remoteVncPort"/>.
    /// The profile's own forwards and remote command are intentionally omitted.
    /// </summary>
    public static List<string> VncTunnelArguments(SshProfile profile, int localPort, int remoteVncPort)
    {
        var args = new List<string> { "-N" };

        if (profile.Compression)
            args.Add("-C");
        if (profile.KeepAlive)
            args.AddRange(new[] { "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3" });
        if (profile.ConnectTimeout > 0)
            args.AddRange(new[] { "-o", $"ConnectTimeout={profile.ConnectTimeout}" });

        var hostKeyValue = profile.StrictHostKeyChecking.OptionValue();
        if (hostKeyValue != null)
            args.AddRange(new[] { "-o", $"StrictHostKeyChecking={hostKeyValue}" });

        args.AddRange(new[] { "-o", "ExitOnForwardFailure=yes" });

        if (int.TryParse(profile.Port.Trim(), out var port) && port != 22)
            args.AddRange(new[] { "-p", port.ToString() });

        var identity = profile.IdentityFile.Trim();
        if (identity.Length > 0)
            args.AddRange(new[] { "-i", ExpandPath(identity), "-o", "IdentitiesOnly=yes" });

        var jump = profile.JumpHost.Trim();
        if (jump.Length > 0)
            args.AddRange(new[] { "-J", jump });

        args.AddRange(new[] { "-L", $"127.0.0.1:{localPort}:127.0.0.1:{remoteVncPort}" });

        args.Add(Destination(profile));
        return args;
    }

    /// <summary>The ssh forward flag + spec for a single forward, or null when incomplete.</summary>
    public static (string Flag, string Spec)? ForwardOption(PortForward forward)
    {
        var bind = forward.BindAddress.Trim();
        var bindPrefix = bind.Length == 0 ? "" : $"{bind}:";
        switch (forward.Type)
        {
            case ForwardType.Local:
            case ForwardType.Remote:
                if (string.IsNullOrEmpty(forward.ListenPort) || string.IsNullOrEmpty(forward.TargetPort))
                    return null;
                var thost = string.IsNullOrEmpty(forward.TargetHost) ? "localhost" : forward.TargetHost;
                return (forward.Type.Flag(), $"{bindPrefix}{forward.ListenPort}:{thost}:{forward.TargetPort}");
            case ForwardType.Dynamic:
                if (string.IsNullOrEmpty(forward.ListenPort))
                    return null;
                return (forward.Type.Flag(), $"{bindPrefix}{forward.ListenPort}");
            default:
                return null;
        }
    }

    private const string ShellSafe =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_./:@=,+";

    public static string ShellQuote(string s)
    {
        if (s.Length == 0) return "''";
        if (s.All(c => ShellSafe.IndexOf(c) >= 0)) return s;
        return "'" + s.Replace("'", "'\\''") + "'";
    }
}
