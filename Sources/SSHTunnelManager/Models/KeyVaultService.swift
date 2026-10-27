import Foundation

/// Bridges the macOS app to an Azure Key Vault that escrows edge-device
/// credentials and the SSH user-CA. Vault coordinates come from `AppSettings`
/// so dev vs prod is a config switch, never hardcoded.
///
/// Mirrors the cross-platform C# `KeyVaultService`. Rather than bundle an Azure
/// SDK, it shells out to the Azure CLI (`az`) the operator already signs in with,
/// and to `ssh-keygen` for certificate signing.
enum KeyVaultService {

    struct Result {
        let ok: Bool
        let message: String
        let value: String?
        static func fail(_ m: String) -> Result { Result(ok: false, message: m, value: nil) }
        static func success(_ m: String, value: String? = nil) -> Result { Result(ok: true, message: m, value: value) }
    }

    /// The device "unit" used to build escrow secret names: the profile's explicit
    /// `keyVaultUnit` override, else the host's first DNS label, lower-cased.
    static func deriveUnit(for profile: SSHProfile) -> String {
        let override = profile.keyVaultUnit.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty { return override.lowercased() }
        let host = profile.host.trimmingCharacters(in: .whitespaces)
        if let dot = host.firstIndex(of: ".") { return String(host[..<dot]).lowercased() }
        return host.lowercased()
    }

    /// Vault short name extracted from the configured URI (first host label).
    private static func vaultName(from uri: String) -> String? {
        guard let url = URL(string: uri.trimmingCharacters(in: .whitespaces)),
              let host = url.host else { return nil }
        return host.split(separator: ".").first.map(String.init)
    }

    // MARK: - Secret reads (Phase B)

    /// Read a single secret's value via `az keyvault secret show`.
    static func getSecret(_ name: String) async -> (value: String?, error: String) {
        let s = AppSettings.shared
        guard let vault = vaultName(from: s.keyVaultUri) else {
            return (nil, "No Key Vault URI is configured (Settings → Key Vault).")
        }
        var args = ["keyvault", "secret", "show",
                    "--vault-name", vault,
                    "--name", name,
                    "--query", "value", "-o", "tsv"]
        let sub = s.keyVaultSubscriptionId.trimmingCharacters(in: .whitespaces)
        if !sub.isEmpty { args += ["--subscription", sub] }

        let (code, out, err) = await runProcess(tool: "az", args: args)
        if code == 0 {
            let value = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? (nil, "Secret '\(name)' was empty.") : (value, "")
        }
        if err.contains("not found") || err.contains("SecretNotFound") {
            return (nil, "Secret '\(name)' not found in the vault.")
        }
        if err.contains("Forbidden") || err.contains("does not have secrets get permission") {
            return (nil, "Access denied reading '\(name)'. Your Azure account needs a get/list secret policy on the vault.")
        }
        if err.contains("az login") || err.contains("Please run 'az login'") {
            return (nil, "Not signed in to Azure. Run `az login` first.")
        }
        return (nil, "Reading '\(name)' failed: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    /// Read the per-device break-glass OS password (`os-snsadmin-<unit>`).
    static func getBreakGlassPassword(unit: String) async -> Result {
        let name = AppSettings.shared.keyVaultOsSecretPrefix + unit
        let (value, error) = await getSecret(name)
        guard let value else { return .fail(error) }
        return .success("Retrieved \(name).", value: value)
    }

    /// Read the per-device app-stack password (`app-stack-<unit>`).
    static func getAppStackPassword(unit: String) async -> Result {
        let name = AppSettings.shared.keyVaultAppStackSecretPrefix + unit
        let (value, error) = await getSecret(name)
        guard let value else { return .fail(error) }
        return .success("Retrieved \(name).", value: value)
    }

    // MARK: - Certificate signing (Phase A)

    /// Refresh the operator's short-lived SSH certificate: fetch the user-CA
    /// private key from the vault and sign `<identityFile>.pub` with `ssh-keygen -s`,
    /// writing `<identityFile>-cert.pub` so OpenSSH presents it automatically.
    /// Dev shortcut — production should use a signing service so the CA never leaves it.
    static func refreshCertificate(identityFile: String, unit: String) async -> Result {
        let key = SSHCommandBuilder.expandPath(identityFile.trimmingCharacters(in: .whitespaces))
        if key.isEmpty {
            return .fail("Set an identity file (private key) first — the certificate is signed for its public key.")
        }
        let pub = key + ".pub"
        if !FileManager.default.fileExists(atPath: pub) {
            return .fail("Public key not found: \(pub). Generate it with `ssh-keygen -y -f <key> > <key>.pub`.")
        }

        let s = AppSettings.shared
        let (caKey, caErr) = await getSecret(s.keyVaultCaPrivateSecretName.trimmingCharacters(in: .whitespaces))
        guard let caKey else { return .fail(caErr) }

        // Stage the CA key in a 0600 temp file; delete it afterwards.
        let caPath = NSTemporaryDirectory() + "rs-ca-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: caPath) }
        do {
            let contents = caKey.hasSuffix("\n") ? caKey : caKey + "\n"
            try contents.write(toFile: caPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: caPath)
        } catch {
            return .fail("Could not stage the CA key: \(error.localizedDescription)")
        }

        let principals = s.keyVaultCertPrincipals.trimmingCharacters(in: .whitespaces).isEmpty
            ? "snsadmin" : s.keyVaultCertPrincipals.trimmingCharacters(in: .whitespaces)
        let validity = s.keyVaultCertValidity.trimmingCharacters(in: .whitespaces).isEmpty
            ? "+1d" : s.keyVaultCertValidity.trimmingCharacters(in: .whitespaces)
        let user = NSUserName()
        let identityComment = unit.isEmpty ? user : "\(user)@\(unit)"

        let (code, out, err) = await runProcess(tool: "ssh-keygen",
            args: ["-s", caPath, "-I", identityComment, "-n", principals, "-V", validity, pub])
        if code != 0 {
            return .fail("ssh-keygen signing failed: \((err + out).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let certPath = key + "-cert.pub"
        return FileManager.default.fileExists(atPath: certPath)
            ? .success("Certificate written: \(certPath) (valid \(validity), principals: \(principals)).")
            : .success("ssh-keygen reported success but the certificate file was not found.")
    }

    // MARK: - Device provisioning (Phase C)

    /// Push an `escrow.env` to a device and optionally trigger the package upgrade.
    /// Requires the operator to currently have a working login to the device.
    static func provisionDevice(profile: SSHProfile, escrowEnvContents: String,
                                triggerUpgrade: Bool, upgradeCommand: String) async -> Result {
        let dest = SSHCommandBuilder.destination(for: profile)
        if dest.isEmpty { return .fail("The profile has no host to provision.") }

        let baseOpts = baseSSHOptions(for: profile)
        let remoteWrite =
            "sudo install -d -m 0750 /etc/s2labs && " +
            "sudo tee /etc/s2labs/escrow.env >/dev/null <<'RS_ESCROW_EOF'\n" +
            escrowEnvContents.replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\n")) + "\n" +
            "RS_ESCROW_EOF\n" +
            "sudo chmod 0640 /etc/s2labs/escrow.env"

        let (wCode, _, wErr) = await runProcess(tool: SSHCommandBuilder.sshPath,
            args: baseOpts + [dest, remoteWrite], resolveViaEnv: false)
        if wCode != 0 {
            return .fail("Writing /etc/s2labs/escrow.env failed: \(wErr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if !triggerUpgrade { return .success("escrow.env written to /etc/s2labs/escrow.env.") }

        let cmd = upgradeCommand.trimmingCharacters(in: .whitespaces).isEmpty ? "sudo s2labs-upgrade" : upgradeCommand
        let (uCode, uOut, uErr) = await runProcess(tool: SSHCommandBuilder.sshPath,
            args: baseOpts + [dest, cmd], resolveViaEnv: false)
        return uCode == 0
            ? .success("escrow.env written and upgrade triggered.\n\(uOut.trimmingCharacters(in: .whitespacesAndNewlines))")
            : .fail("escrow.env written, but upgrade command failed: \((uErr + uOut).trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    /// Minimal ssh connection options (identity / port / host-key) for a one-off command.
    private static func baseSSHOptions(for profile: SSHProfile) -> [String] {
        var opts = ["-o", "BatchMode=no"]
        if let port = Int(profile.port.trimmingCharacters(in: .whitespaces)), port != 22 {
            opts += ["-p", String(port)]
        }
        let identity = profile.identityFile.trimmingCharacters(in: .whitespaces)
        if !identity.isEmpty {
            opts += ["-i", SSHCommandBuilder.expandPath(identity), "-o", "IdentitiesOnly=yes"]
        }
        let jump = profile.jumpHost.trimmingCharacters(in: .whitespaces)
        if !jump.isEmpty { opts += ["-J", jump] }
        return opts
    }

    // MARK: - Process helper

    /// Run a tool and capture its output. When `resolveViaEnv` is true the tool is
    /// found on PATH via `/usr/bin/env` (so `az` / `ssh-keygen` resolve regardless
    /// of install location); otherwise `tool` is an absolute path.
    private static func runProcess(tool: String, args: [String], resolveViaEnv: Bool = true)
        async -> (code: Int32, stdout: String, stderr: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                if resolveViaEnv {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = [tool] + args
                } else {
                    process.executableURL = URL(fileURLWithPath: tool)
                    process.arguments = args
                }
                var env = ProcessInfo.processInfo.environment
                // Ensure Homebrew / CLI install locations are on PATH for `az`.
                let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                env["PATH"] = (env["PATH"].map { "\($0):\(extraPaths)" }) ?? extraPaths
                process.environment = env

                let outPipe = Pipe(), errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, "", error.localizedDescription))
                    return
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (
                    process.terminationStatus,
                    String(data: outData, encoding: .utf8) ?? "",
                    String(data: errData, encoding: .utf8) ?? ""))
            }
        }
    }
}
