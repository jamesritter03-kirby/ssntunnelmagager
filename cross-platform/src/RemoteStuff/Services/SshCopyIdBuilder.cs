using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using RemoteStuff.Models;

namespace RemoteStuff.Services;

/// <summary>
/// Builds a one-click "set up passwordless login" flow using <c>ssh-copy-id</c>.
/// A faithful cross-platform port of the original Swift <c>SSHCopyIDBuilder</c>.
/// </summary>
public static class SshCopyIdBuilder
{
    public const string CopyIdPath = "/usr/bin/ssh-copy-id";
    public const string KeygenPath = "/usr/bin/ssh-keygen";

    /// <summary>Public-key basenames we look for in <c>~/.ssh</c>, most-preferred first.</summary>
    public static readonly string[] DefaultKeyNames = { "id_ed25519", "id_ecdsa", "id_rsa" };

    public static string SshDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh");

    /// <summary>
    /// The public key this profile should publish: its identity file's <c>.pub</c>
    /// when present, else the first existing default key, else <c>null</c>.
    /// </summary>
    public static string? PublicKey(SshProfile profile)
    {
        var identity = profile.IdentityFile.Trim();
        if (identity.Length > 0)
        {
            var priv = SshCommandBuilder.ExpandPath(identity);
            var pub = priv.EndsWith(".pub") ? priv : priv + ".pub";
            return File.Exists(pub) ? pub : null;
        }
        return ExistingDefaultPublicKey();
    }

    /// <summary>The first default public key that exists in <c>~/.ssh</c>, or <c>null</c>.</summary>
    public static string? ExistingDefaultPublicKey()
    {
        foreach (var name in DefaultKeyNames)
        {
            var pub = Path.Combine(SshDirectory, name + ".pub");
            if (File.Exists(pub)) return pub;
        }
        return null;
    }

    /// <summary>Where a freshly generated key is written when the user has none (ed25519).</summary>
    public static string DefaultGeneratedPublicKey() => Path.Combine(SshDirectory, "id_ed25519.pub");

    /// <summary>The private-key path matching a public key (drops a trailing <c>.pub</c>).</summary>
    public static string PrivateKeyPath(string pub) => pub.EndsWith(".pub") ? pub[..^4] : pub;

    /// <summary><c>ssh-copy-id</c> arguments (program name excluded), in order.</summary>
    public static List<string> Arguments(SshProfile profile, string publicKey)
    {
        var args = new List<string> { "-i", SshCommandBuilder.ExpandPath(publicKey) };
        if (int.TryParse(profile.Port.Trim(), out var port) && port != 22)
            args.AddRange(new[] { "-p", port.ToString() });
        var jump = profile.JumpHost.Trim();
        if (jump.Length > 0)
            args.AddRange(new[] { "-o", $"ProxyJump={jump}" });
        var host = profile.Host.Trim();
        var user = profile.Username.Trim();
        args.Add(user.Length == 0 ? host : $"{user}@{host}");
        return args;
    }

    /// <summary>A human-readable, copy-pasteable command preview.</summary>
    public static string CommandPreview(SshProfile profile, string publicKey)
        => string.Join(" ", new[] { "ssh-copy-id" }.Concat(Arguments(profile, publicKey))
            .Select(SshCommandBuilder.ShellQuote));

    /// <summary>
    /// The shell script the key-setup terminal tab runs: an optional
    /// <c>ssh-keygen</c> (when generating a new key), then <c>ssh-copy-id</c>,
    /// bracketed by friendly status messages. Passed to the login shell via <c>-c</c>.
    /// </summary>
    public static string SetupScript(SshProfile profile, string publicKey, bool generateKey)
    {
        static string Q(string s) => SshCommandBuilder.ShellQuote(s);
        var pub = SshCommandBuilder.ExpandPath(publicKey);
        var copyCmd = string.Join(" ", new[] { CopyIdPath }.Concat(Arguments(profile, publicKey)).Select(Q));
        var host = profile.Host.Trim();
        var user = profile.Username.Trim();
        var dest = user.Length == 0 ? host : $"{user}@{host}";

        var lines = new List<string>
        {
            "export PATH=\"/usr/bin:/bin:/usr/sbin:/sbin:$PATH\"",
            $"echo {Q($"Set up passwordless SSH login  →  {dest}")}"
        };
        if (generateKey)
        {
            var priv = PrivateKeyPath(pub);
            lines.Add($"echo {Q($"No SSH key found — generating one: {priv}")}");
            lines.Add($"{Q(KeygenPath)} -t ed25519 -f {Q(priv)} -N '' -q || exit 1");
        }
        lines.Add($"echo {Q($"Publishing public key: {pub}")}");
        lines.Add($"echo {Q("You may be asked for the account password once.")}");
        lines.Add("echo");
        lines.Add(copyCmd);
        lines.Add("__rc=$?");
        lines.Add("echo");
        var okMsg = Q("✓ Done — future connections to this profile can sign in with the key (no password).");
        var failMsg = Q("✗ ssh-copy-id did not finish. Review the output above, then try again.");
        lines.Add($"if [ $__rc -eq 0 ]; then echo {okMsg}; else echo {failMsg}; fi");
        lines.Add($"echo {Q("— You can close this tab. —")}");
        return string.Join("\n", lines);
    }
}
