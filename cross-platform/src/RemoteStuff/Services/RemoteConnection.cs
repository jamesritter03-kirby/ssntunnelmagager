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
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        // Load a private key into a PrivateKeyAuthenticationMethod, using the given
        // passphrase only when one is supplied. Returns null for missing/unloadable keys.
        AuthenticationMethod? KeyMethod(string keyPath, string? passphrase)
        {
            if (string.IsNullOrEmpty(keyPath) || !File.Exists(keyPath) || !seen.Add(keyPath))
                return null;
            try
            {
                var keyFile = string.IsNullOrEmpty(passphrase)
                    ? new PrivateKeyFile(keyPath)
                    : new PrivateKeyFile(keyPath, passphrase);
                return new PrivateKeyAuthenticationMethod(user, keyFile);
            }
            catch
            {
                // Skip keys that can't be loaded (e.g. passphrase-protected with no/other passphrase).
                return null;
            }
        }

        // 1) The profile's explicit identity file is the user's chosen credential, so try
        //    it first (the saved password doubles as its passphrase for encrypted keys).
        var explicitKey = SshCommandBuilder.ExpandPath(profile.IdentityFile?.Trim() ?? "");
        if (!string.IsNullOrEmpty(explicitKey) && KeyMethod(explicitKey, password) is { } explicitMethod)
            methods.Add(explicitMethod);

        // 2) A saved password is an explicit credential too — offer it BEFORE the default
        //    ~/.ssh keys. Otherwise every default key (Windows OpenSSH generates unencrypted
        //    ones by default) is offered first and can exhaust the server's MaxAuthTries
        //    before the password is ever tried, which fails auth on Windows while working on
        //    macOS (where the default-key set is usually just the user's own working key).
        if (!string.IsNullOrEmpty(password))
            methods.Add(new PasswordAuthenticationMethod(user, password));

        // 3) Fall back to the standard default keys in ~/.ssh (agentless parity with the
        //    system `ssh` CLI). Load them WITHOUT the saved password as a passphrase — a
        //    login password is almost never a random default key's passphrase.
        var sshDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh");
        foreach (var name in new[] { "id_ed25519", "id_ecdsa", "id_rsa", "id_dsa" })
            if (KeyMethod(Path.Combine(sshDir, name), null) is { } defaultMethod)
                methods.Add(defaultMethod);

        if (methods.Count == 0)
            methods.Add(new NoneAuthenticationMethod(user));

        var info = new ConnectionInfo(host, port, user, methods.ToArray());
        if (profile.ConnectTimeout > 0)
            info.Timeout = TimeSpan.FromSeconds(profile.ConnectTimeout);
        return info;
    }
}
