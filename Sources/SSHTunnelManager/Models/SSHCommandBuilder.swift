import Foundation

/// Builds the `ssh` argument list (and a human-readable preview) for a profile.
enum SSHCommandBuilder {
    static let sshPath = "/usr/bin/ssh"

    /// Expand a leading `~` to the user's home directory.
    static func expandPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Build the argument list passed to `/usr/bin/ssh` for a profile.
    static func arguments(for profile: SSHProfile) -> [String] {
        var args: [String] = []

        if !profile.openShell {
            args.append("-N")
        }
        if profile.compression {
            args.append("-C")
        }
        if profile.verbose {
            args.append("-v")
        }
        if profile.keepAlive {
            args += ["-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3"]
        }
        if !profile.forwards.isEmpty {
            // Make ssh exit (and report) if a requested forward can't be set up.
            args += ["-o", "ExitOnForwardFailure=yes"]
        }
        if let port = Int(profile.port.trimmingCharacters(in: .whitespaces)), port != 22 {
            args += ["-p", "\(port)"]
        }
        let identity = profile.identityFile.trimmingCharacters(in: .whitespaces)
        if !identity.isEmpty {
            args += ["-i", expandPath(identity)]
        }
        let jump = profile.jumpHost.trimmingCharacters(in: .whitespaces)
        if !jump.isEmpty {
            args += ["-J", jump]
        }

        for forward in profile.forwards {
            let bind = forward.bindAddress.trimmingCharacters(in: .whitespaces)
            let bindPrefix = bind.isEmpty ? "" : "\(bind):"
            switch forward.type {
            case .local, .remote:
                guard !forward.listenPort.isEmpty, !forward.targetPort.isEmpty else { continue }
                let host = forward.targetHost.isEmpty ? "localhost" : forward.targetHost
                args += [forward.type.flag, "\(bindPrefix)\(forward.listenPort):\(host):\(forward.targetPort)"]
            case .dynamic:
                guard !forward.listenPort.isEmpty else { continue }
                args += [forward.type.flag, "\(bindPrefix)\(forward.listenPort)"]
            }
        }

        // Extra raw options, naive whitespace split (good enough for flags like `-o Key=Val`).
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
        (["ssh"] + arguments(for: profile)).map(shellQuote).joined(separator: " ")
    }

    static let shellSafe = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_./:@=,+")

    static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        if s.unicodeScalars.allSatisfy({ shellSafe.contains($0) }) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
