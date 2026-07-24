using System;
using System.Collections.Generic;
using System.IO;
using Renci.SshNet;
using RemoteStuff.Models;

namespace RemoteStuff.Services;

/// <summary>Builds SSH.NET connection objects from an <see cref="SshProfile"/>.</summary>
public static class RemoteConnection
{
    public static ConnectionInfo BuildConnectionInfo(SshProfile profile, string? password)
    {
        var host = string.IsNullOrWhiteSpace(profile.Host) ? "localhost" : profile.Host.Trim();
        var port = int.TryParse(profile.Port, out var p) && p > 0 ? p : 22;
        var user = string.IsNullOrWhiteSpace(profile.Username)
            ? Environment.UserName
            : profile.Username.Trim();

        var methods = new List<AuthenticationMethod>();

        // 1) Explicit identity file from the profile (if any), then the standard
        //    default keys in ~/.ssh — this mirrors what the system `ssh` CLI does,
        //    so key-based profiles that connect in a terminal also work over SFTP.
        var keyPaths = new List<string>();
        var explicitKey = SshCommandBuilder.ExpandPath(profile.IdentityFile?.Trim() ?? "");
        if (!string.IsNullOrEmpty(explicitKey))
            keyPaths.Add(explicitKey);

        var sshDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh");
        foreach (var name in new[] { "id_ed25519", "id_ecdsa", "id_rsa", "id_dsa" })
            keyPaths.Add(Path.Combine(sshDir, name));

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var keyPath in keyPaths)
        {
            if (string.IsNullOrEmpty(keyPath) || !File.Exists(keyPath) || !seen.Add(keyPath))
                continue;
            try
            {
                var keyFile = string.IsNullOrEmpty(password)
                    ? new PrivateKeyFile(keyPath)
                    : new PrivateKeyFile(keyPath, password);
                methods.Add(new PrivateKeyAuthenticationMethod(user, keyFile));
            }
            catch
            {
                // Skip keys that can't be loaded (e.g. passphrase-protected with no/other passphrase).
            }
        }

        if (!string.IsNullOrEmpty(password))
            methods.Add(new PasswordAuthenticationMethod(user, password));

        if (methods.Count == 0)
            methods.Add(new NoneAuthenticationMethod(user));

        var info = new ConnectionInfo(host, port, user, methods.ToArray());
        if (profile.ConnectTimeout > 0)
            info.Timeout = TimeSpan.FromSeconds(profile.ConnectTimeout);
        return info;
    }
}
