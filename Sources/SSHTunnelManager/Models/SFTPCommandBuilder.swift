import Foundation

/// Builds the `sftp` argument list (and a human-readable preview) for a profile,
/// plus quoting helpers for paths typed at the interactive `sftp>` prompt.
///
/// `sftp` shares SSH's authentication and connection options but uses a few
/// different flags from `ssh` — most notably `-P` (capital) for the port.
enum SFTPCommandBuilder {
    static let sftpPath = "/usr/bin/sftp"

    /// Build the argument list passed to `/usr/bin/sftp` for a profile. Only the
    /// connection-related options apply (port forwards are an `ssh`-only concept).
    static func arguments(for profile: SSHProfile) -> [String] {
        var args: [String] = []

        if profile.compression { args.append("-C") }
        if profile.verbose { args.append("-v") }

        // sftp uses -P (capital) for the port, unlike ssh's -p.
        if let port = Int(profile.port.trimmingCharacters(in: .whitespaces)), port != 22 {
            args += ["-P", "\(port)"]
        }
        let identity = profile.identityFile.trimmingCharacters(in: .whitespaces)
        if !identity.isEmpty {
            args += ["-i", SSHCommandBuilder.expandPath(identity)]
        }
        let jump = profile.jumpHost.trimmingCharacters(in: .whitespaces)
        if !jump.isEmpty {
            args += ["-J", jump]
        }
        if profile.keepAlive {
            args += ["-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3"]
        }

        // Extra raw options, naive whitespace split (matches SSHCommandBuilder).
        let extra = profile.extraOptions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            args += extra.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        }

        // Destination (must come last).
        let host = profile.host.trimmingCharacters(in: .whitespaces)
        let user = profile.username.trimmingCharacters(in: .whitespaces)
        let dest = user.isEmpty ? host : "\(user)@\(host)"
        if !dest.isEmpty {
            args.append(dest)
        }
        return args
    }

    /// A human-readable, copy-pasteable command preview (with simple shell quoting).
    static func commandPreview(for profile: SSHProfile) -> String {
        (["sftp"] + arguments(for: profile)).map(SSHCommandBuilder.shellQuote).joined(separator: " ")
    }

    /// Quote a path for use as an argument to `put` / `get` / `lcd` at the
    /// interactive `sftp>` prompt. sftp's lexer treats a backslash inside double
    /// quotes as an escape, so we escape `\` and `"`.
    static func quotePath(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
