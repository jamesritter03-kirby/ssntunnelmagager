import Foundation

/// Builds a one-click "set up passwordless login" flow using `ssh-copy-id`.
///
/// It works out which **public key** to publish for a profile, assembles the
/// `ssh-copy-id` argument list (sharing the profile's port, jump host and key),
/// and renders the small shell script the key-setup terminal tab runs — which,
/// when needed, first generates a new key with `ssh-keygen`, then copies it, and
/// prints a friendly result. Pure string-building so it stays easy to test.
enum SSHCopyIDBuilder {
    static let copyIDPath = "/usr/bin/ssh-copy-id"
    static let keygenPath = "/usr/bin/ssh-keygen"

    /// Public-key basenames we look for in `~/.ssh`, most-preferred first.
    static let defaultKeyNames = ["id_ed25519", "id_ecdsa", "id_rsa"]

    static var sshDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
    }

    // MARK: - Key resolution

    /// The public key this profile should publish:
    /// 1. its identity file's `.pub` (when an identity file is set and that
    ///    `.pub` exists on disk); else
    /// 2. the first existing default key in `~/.ssh`; else
    /// 3. `nil` — nothing to copy, so the caller offers to generate one.
    static func publicKey(for profile: SSHProfile) -> String? {
        let identity = profile.identityFile.trimmingCharacters(in: .whitespaces)
        if !identity.isEmpty {
            let priv = SSHCommandBuilder.expandPath(identity)
            let pub = priv.hasSuffix(".pub") ? priv : priv + ".pub"
            return FileManager.default.fileExists(atPath: pub) ? pub : nil
        }
        return existingDefaultPublicKey()
    }

    /// The first default public key that exists in `~/.ssh`, or `nil`.
    static func existingDefaultPublicKey() -> String? {
        let fm = FileManager.default
        for name in defaultKeyNames {
            let pub = (sshDirectory as NSString).appendingPathComponent(name + ".pub")
            if fm.fileExists(atPath: pub) { return pub }
        }
        return nil
    }

    /// Where a freshly generated key is written when the user has none (ed25519).
    static func defaultGeneratedPublicKey() -> String {
        (sshDirectory as NSString).appendingPathComponent("id_ed25519.pub")
    }

    /// The private-key path matching a public key (drops a trailing `.pub`).
    static func privateKeyPath(forPublicKey pub: String) -> String {
        pub.hasSuffix(".pub") ? String(pub.dropLast(4)) : pub
    }

    // MARK: - Command building

    /// `ssh-copy-id` arguments (program name excluded), in order. Mirrors the
    /// connection-relevant options of a normal SSH connection.
    static func arguments(for profile: SSHProfile, publicKey: String) -> [String] {
        var args: [String] = ["-i", SSHCommandBuilder.expandPath(publicKey)]
        if let port = Int(profile.port.trimmingCharacters(in: .whitespaces)), port != 22 {
            args += ["-p", "\(port)"]
        }
        let jump = profile.jumpHost.trimmingCharacters(in: .whitespaces)
        if !jump.isEmpty {
            args += ["-o", "ProxyJump=\(jump)"]
        }
        let host = profile.host.trimmingCharacters(in: .whitespaces)
        let user = profile.username.trimmingCharacters(in: .whitespaces)
        args.append(user.isEmpty ? host : "\(user)@\(host)")
        return args
    }

    /// A human-readable, copy-pasteable command preview.
    static func commandPreview(for profile: SSHProfile, publicKey: String) -> String {
        (["ssh-copy-id"] + arguments(for: profile, publicKey: publicKey))
            .map(SSHCommandBuilder.shellQuote).joined(separator: " ")
    }

    /// The shell script the key-setup terminal tab runs: an optional `ssh-keygen`
    /// (when generating a new key), then `ssh-copy-id`, bracketed by friendly
    /// status messages. Passed to the login shell via `-c`.
    static func setupScript(for profile: SSHProfile, publicKey: String,
                            generateKey: Bool) -> String {
        let q = SSHCommandBuilder.shellQuote
        let pub = SSHCommandBuilder.expandPath(publicKey)
        let copyCmd = ([copyIDPath] + arguments(for: profile, publicKey: publicKey))
            .map(q).joined(separator: " ")
        let dest = profile.subtitle

        var lines: [String] = []
        // Guarantee ssh / ssh-keygen / ssh-copy-id resolve even if the app was
        // launched with a minimal PATH (ssh-copy-id calls `ssh` by name).
        lines.append(#"export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH""#)
        lines.append("echo \(q("Set up passwordless SSH login  →  \(dest)"))")
        if generateKey {
            let priv = privateKeyPath(forPublicKey: pub)
            lines.append("echo \(q("No SSH key found — generating one: \(priv)"))")
            lines.append("\(q(keygenPath)) -t ed25519 -f \(q(priv)) -N '' -q || exit 1")
        }
        lines.append("echo \(q("Publishing public key: \(pub)"))")
        lines.append("echo \(q("You may be asked for the account password once."))")
        lines.append("echo")
        lines.append(copyCmd)
        lines.append("__rc=$?")
        lines.append("echo")
        let okMsg = q("✓ Done — future connections to this profile can sign in with the key (no password).")
        let failMsg = q("✗ ssh-copy-id did not finish. Review the output above, then try again.")
        lines.append("if [ $__rc -eq 0 ]; then echo \(okMsg); else echo \(failMsg); fi")
        lines.append("echo \(q("— You can close this tab. —"))")
        return lines.joined(separator: "\n")
    }
}
