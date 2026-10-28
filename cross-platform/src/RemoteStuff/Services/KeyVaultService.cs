using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Azure;
using Azure.Core;
using Azure.Identity;
using Azure.Security.KeyVault.Secrets;
using RemoteStuff.Models;

namespace RemoteStuff.Services;

/// <summary>
/// Bridges the app to an Azure Key Vault that escrows edge-device credentials and
/// the SSH user-CA. All vault coordinates (URI, subscription, secret names) come
/// from <see cref="AppSettings"/> so dev vs prod is a config switch, never hardcoded.
///
/// Three capabilities map to the integration phases:
///  - Phase A: <see cref="RefreshCertificateAsync"/> signs the operator's public key
///    with the CA fetched from the vault (dev shortcut; prod should use a signing
///    service so the CA key never leaves the server).
///  - Phase B: <see cref="GetBreakGlassPasswordAsync"/> / <see cref="GetAppStackPasswordAsync"/>
///    read the per-device escrowed secrets.
///  - Phase C: <see cref="ProvisionDeviceAsync"/> pushes the escrow env + triggers upgrade.
/// </summary>
public sealed class KeyVaultService
{
    private readonly AppSettings _settings;

    public KeyVaultService(AppSettings settings) => _settings = settings;

    /// <summary>Result of an operation: Ok plus a human message (and optional value).</summary>
    public readonly record struct Result(bool Ok, string Message, string? Value = null)
    {
        public static Result Fail(string message) => new(false, message);
        public static Result Success(string message, string? value = null) => new(true, message, value);
    }

    /// <summary>
    /// The device's OS hostname (its serial) used to build escrow secret names: the
    /// profile's explicit <see cref="SshProfile.KeyVaultHostname"/>, else the connection
    /// host's first DNS label (e.g. <c>epc01</c> from <c>epc01.lan</c>), lower-cased.
    /// This is the device hostname, NOT the customer-editable Unit ID.
    /// </summary>
    public static string DeriveHostname(SshProfile profile)
    {
        var name = profile.KeyVaultHostname?.Trim();
        if (string.IsNullOrEmpty(name))
        {
            var host = profile.Host?.Trim() ?? "";
            var dot = host.IndexOf('.');
            name = dot > 0 ? host[..dot] : host;
        }
        return name.ToLowerInvariant();
    }

    private bool TryBuildClient(out SecretClient? client, out string error)
    {
        client = null;
        error = "";
        var uri = _settings.KeyVaultUri?.Trim();
        if (string.IsNullOrEmpty(uri) || !Uri.TryCreate(uri, UriKind.Absolute, out var vaultUri))
        {
            error = "No Key Vault URI is configured (Settings → Key Vault).";
            return false;
        }

        try
        {
            // Try Azure CLI first (an operator who ran `az login` gets silent auth),
            // then fall back to an interactive browser sign-in. Both honour an
            // access-policy vault as long as the operator's object-id has get/list.
            TokenCredential credential = new ChainedTokenCredential(
                new AzureCliCredential(),
                new InteractiveBrowserCredential());
            client = new SecretClient(vaultUri, credential);
            return true;
        }
        catch (Exception ex)
        {
            error = $"Azure sign-in failed: {ex.Message}";
            return false;
        }
    }

    /// <summary>Fetch a single secret's value by name. Returns null on any failure
    /// (with the reason in <paramref name="error"/>).</summary>
    public async Task<string?> GetSecretAsync(string name, CancellationToken ct = default)
    {
        var (value, _) = await TryGetSecretAsync(name, ct).ConfigureAwait(false);
        return value;
    }

    private async Task<(string? value, string error)> TryGetSecretAsync(string name, CancellationToken ct)
    {
        if (!TryBuildClient(out var client, out var err) || client is null)
            return (null, err);
        try
        {
            Response<KeyVaultSecret> resp = await client.GetSecretAsync(name, cancellationToken: ct)
                                                        .ConfigureAwait(false);
            return (resp.Value.Value, "");
        }
        catch (RequestFailedException rfe) when (rfe.Status == 404)
        {
            return (null, $"Secret '{name}' not found in the vault.");
        }
        catch (RequestFailedException rfe) when (rfe.Status == 403)
        {
            return (null, $"Access denied reading '{name}'. Your Azure account needs a get/list secret policy on the vault.");
        }
        catch (Exception ex)
        {
            return (null, $"Reading '{name}' failed: {ex.Message}");
        }
    }

    // ---- Phase B: escrowed password reads ----------------------------------

    /// <summary>Read the per-device break-glass OS password (<c>os-snsadmin-&lt;hostname&gt;</c>).</summary>
    public async Task<Result> GetBreakGlassPasswordAsync(string hostname, CancellationToken ct = default)
    {
        var secretName = (_settings.KeyVaultOsSecretPrefix ?? "") + hostname;
        var (value, error) = await TryGetSecretAsync(secretName, ct).ConfigureAwait(false);
        return value is null ? Result.Fail(error) : Result.Success($"Retrieved {secretName}.", value);
    }

    /// <summary>Read the per-device app-stack password (<c>app-stack-&lt;hostname&gt;</c>).</summary>
    public async Task<Result> GetAppStackPasswordAsync(string hostname, CancellationToken ct = default)
    {
        var secretName = (_settings.KeyVaultAppStackSecretPrefix ?? "") + hostname;
        var (value, error) = await TryGetSecretAsync(secretName, ct).ConfigureAwait(false);
        return value is null ? Result.Fail(error) : Result.Success($"Retrieved {secretName}.", value);
    }

    // ---- Phase A: certificate signing --------------------------------------

    /// <summary>
    /// Refresh the operator's short-lived SSH certificate: fetch the user-CA private
    /// key from the vault and sign <paramref name="identityFile"/>'s public key with
    /// <c>ssh-keygen -s</c>, writing <c>&lt;identityFile&gt;-cert.pub</c> next to the key
    /// so OpenSSH presents it automatically on the next connection.
    ///
    /// This is the DEV shortcut. In production the CA key must never leave a signing
    /// service — swap this for a call to that service once it exists.
    /// </summary>
    public async Task<Result> RefreshCertificateAsync(string identityFile, string hostname, CancellationToken ct = default)
    {
        identityFile = SshCommandBuilder.ExpandPath(identityFile?.Trim() ?? "");
        if (string.IsNullOrEmpty(identityFile))
            return Result.Fail("Set an identity file (private key) first — the certificate is signed for its public key.");

        var pubPath = identityFile + ".pub";
        if (!File.Exists(pubPath))
            return Result.Fail($"Public key not found: {pubPath}. Generate it with `ssh-keygen -y -f <key> > <key>.pub`.");

        var keygen = FindSshKeygen();
        if (keygen is null)
            return Result.Fail("ssh-keygen was not found. Install the OpenSSH client.");

        var (caKey, caErr) = await TryGetSecretAsync(_settings.KeyVaultCaPrivateSecretName?.Trim() ?? "", ct)
                                   .ConfigureAwait(false);
        if (caKey is null)
            return Result.Fail(caErr);

        // Stage the CA key in a per-user temp file with 0600 perms; delete it after.
        var caPath = Path.Combine(Path.GetTempPath(), $"rs-ca-{Guid.NewGuid():N}");
        try
        {
            // ssh-keygen requires the key to end with a newline and be mode 0600.
            await File.WriteAllTextAsync(caPath, caKey.EndsWith("\n") ? caKey : caKey + "\n", ct)
                      .ConfigureAwait(false);
            if (!OperatingSystem.IsWindows())
                File.SetUnixFileMode(caPath, UnixFileMode.UserRead | UnixFileMode.UserWrite);

            var principals = string.IsNullOrWhiteSpace(_settings.KeyVaultCertPrincipals)
                ? "snsadmin"
                : _settings.KeyVaultCertPrincipals.Trim();
            var validity = string.IsNullOrWhiteSpace(_settings.KeyVaultCertValidity)
                ? "+1d"
                : _settings.KeyVaultCertValidity.Trim();
            var identityComment = string.IsNullOrEmpty(hostname) ? Environment.UserName : $"{Environment.UserName}@{hostname}";

            // ssh-keygen -s ca -I <id> -n <principals> -V <validity> <pubkey>
            // writes <pubkey without .pub>-cert.pub beside the key.
            var args = new[]
            {
                "-s", caPath,
                "-I", identityComment,
                "-n", principals,
                "-V", validity,
                pubPath
            };

            var (code, stdout, stderr) = await RunProcessAsync(keygen, args, ct).ConfigureAwait(false);
            if (code != 0)
                return Result.Fail($"ssh-keygen signing failed: {stderr.Trim()}{stdout.Trim()}");

            var certPath = identityFile + "-cert.pub";
            return File.Exists(certPath)
                ? Result.Success($"Certificate written: {certPath} (valid {validity}, principals: {principals}).")
                : Result.Success("ssh-keygen reported success but the certificate file was not found.");
        }
        catch (Exception ex)
        {
            return Result.Fail($"Certificate refresh failed: {ex.Message}");
        }
        finally
        {
            try { if (File.Exists(caPath)) File.Delete(caPath); } catch { /* best effort */ }
        }
    }

    // ---- Phase C: device provisioning --------------------------------------

    /// <summary>
    /// Push an <c>escrow.env</c> to a device and (optionally) trigger the package
    /// upgrade, so the app can onboard a device in one click. Runs over the system
    /// <c>ssh</c> binary using the profile's own connection options; requires the
    /// operator to currently have a working (password or cert) login to the device.
    /// </summary>
    public async Task<Result> ProvisionDeviceAsync(SshProfile profile, string escrowEnvContents,
        bool triggerUpgrade, string upgradeCommand, CancellationToken ct = default)
    {
        var ssh = SshCommandBuilder.FindSshExecutable();
        if (ssh is null)
            return Result.Fail("ssh client not found. Install the OpenSSH client.");

        var dest = SshCommandBuilder.Destination(profile);
        if (string.IsNullOrEmpty(dest))
            return Result.Fail("The profile has no host to provision.");

        // Base ssh options (identity, port, host-key policy) without forwards/shell.
        var baseOpts = BaseSshOptions(profile);

        // 1) Write the escrow env atomically via a heredoc piped to a privileged tee.
        var remoteWrite =
            "sudo install -d -m 0750 /etc/s2labs && " +
            "sudo tee /etc/s2labs/escrow.env >/dev/null <<'RS_ESCROW_EOF'\n" +
            escrowEnvContents.Replace("\r\n", "\n").TrimEnd('\n') + "\n" +
            "RS_ESCROW_EOF\n" +
            "sudo chmod 0640 /etc/s2labs/escrow.env";

        var writeArgs = new System.Collections.Generic.List<string>();
        writeArgs.AddRange(baseOpts);
        writeArgs.Add(dest);
        writeArgs.Add(remoteWrite);
        var (wCode, _, wErr) = await RunProcessAsync(ssh, writeArgs.ToArray(), ct).ConfigureAwait(false);
        if (wCode != 0)
            return Result.Fail($"Writing /etc/s2labs/escrow.env failed: {wErr.Trim()}");

        if (!triggerUpgrade)
            return Result.Success("escrow.env written to /etc/s2labs/escrow.env.");

        var cmd = string.IsNullOrWhiteSpace(upgradeCommand) ? "sudo s2labs-upgrade" : upgradeCommand.Trim();
        var upArgs = new System.Collections.Generic.List<string>();
        upArgs.AddRange(baseOpts);
        upArgs.Add(dest);
        upArgs.Add(cmd);
        var (uCode, uOut, uErr) = await RunProcessAsync(ssh, upArgs.ToArray(), ct).ConfigureAwait(false);
        return uCode == 0
            ? Result.Success($"escrow.env written and upgrade triggered.\n{uOut.Trim()}")
            : Result.Fail($"escrow.env written, but upgrade command failed: {uErr.Trim()}{uOut.Trim()}");
    }

    /// <summary>Minimal ssh connection options (identity / port / host-key) for a one-off command.</summary>
    private static System.Collections.Generic.List<string> BaseSshOptions(SshProfile profile)
    {
        var opts = new System.Collections.Generic.List<string> { "-o", "BatchMode=no" };
        if (int.TryParse(profile.Port.Trim(), out var port) && port != 22)
        {
            opts.Add("-p");
            opts.Add(port.ToString());
        }
        var identity = profile.IdentityFile.Trim();
        if (identity.Length > 0)
        {
            opts.Add("-i");
            opts.Add(SshCommandBuilder.ExpandPath(identity));
            opts.Add("-o");
            opts.Add("IdentitiesOnly=yes");
        }
        var jump = profile.JumpHost.Trim();
        if (jump.Length > 0)
        {
            opts.Add("-J");
            opts.Add(jump);
        }
        return opts;
    }

    // ---- process helpers ----------------------------------------------------

    private static string? FindSshKeygen()
    {
        var ssh = SshCommandBuilder.FindSshExecutable();
        if (ssh is not null)
        {
            var dir = Path.GetDirectoryName(ssh);
            if (dir is not null)
            {
                var guess = Path.Combine(dir, OperatingSystem.IsWindows() ? "ssh-keygen.exe" : "ssh-keygen");
                if (File.Exists(guess)) return guess;
            }
        }
        return OperatingSystem.IsWindows() ? "ssh-keygen.exe" : "ssh-keygen";
    }

    private static async Task<(int code, string stdout, string stderr)> RunProcessAsync(
        string exe, string[] args, CancellationToken ct)
    {
        var psi = new ProcessStartInfo
        {
            FileName = exe,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        foreach (var a in args) psi.ArgumentList.Add(a);

        using var proc = new Process { StartInfo = psi };
        var outSb = new StringBuilder();
        var errSb = new StringBuilder();
        proc.OutputDataReceived += (_, e) => { if (e.Data != null) outSb.AppendLine(e.Data); };
        proc.ErrorDataReceived += (_, e) => { if (e.Data != null) errSb.AppendLine(e.Data); };

        proc.Start();
        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();
        await proc.WaitForExitAsync(ct).ConfigureAwait(false);
        return (proc.ExitCode, outSb.ToString(), errSb.ToString());
    }
}
