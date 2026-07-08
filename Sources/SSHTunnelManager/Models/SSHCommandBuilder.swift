import Foundation

/// Builds the `ssh` argument list (and a human-readable preview) for a profile.
enum SSHCommandBuilder {
    static let sshPath = "/usr/bin/ssh"

    /// Expand a leading `~` to the user's home directory.
    static func expandPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Build the argument list passed to `/usr/bin/ssh` for a profile.
    ///
    /// When `controlPath` is supplied, connection multiplexing is enabled
    /// (`ControlMaster=auto`) so port forwards can be added/removed live via
    /// `ssh -O forward` against that control socket. It's harmless if the socket
    /// can't be created — ssh just proceeds without multiplexing.
    static func arguments(for profile: SSHProfile, controlPath: String? = nil) -> [String] {
        var args: [String] = []

        // A remote command runs a program instead of just holding an interactive
        // shell; when one is set we don't pass -N (we want the command to run).
        let remoteCommand = profile.remoteCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasRemoteCommand = !remoteCommand.isEmpty

        if !profile.openShell && !hasRemoteCommand {
            args.append("-N")
        }
        if profile.compression {
            args.append("-C")
        }
        if profile.verbose {
            args.append("-v")
        }
        if profile.forwardAgent {
            args.append("-A")
        }
        // Force a TTY when a remote command needs interactivity (ssh -tt).
        if profile.requestTTY && hasRemoteCommand {
            args += ["-t", "-t"]
        }
        if profile.keepAlive {
            args += ["-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3"]
        }
        if let controlPath, !controlPath.isEmpty {
            args += ["-o", "ControlMaster=auto",
                     "-o", "ControlPath=\(controlPath)",
                     "-o", "ControlPersist=no"]
        }
        if profile.addKeysToAgent {
            args += ["-o", "AddKeysToAgent=yes"]
        }
        if profile.connectTimeout > 0 {
            args += ["-o", "ConnectTimeout=\(profile.connectTimeout)"]
        }
        if let hostKeyValue = profile.strictHostKeyChecking.optionValue {
            args += ["-o", "StrictHostKeyChecking=\(hostKeyValue)"]
        }
        for env in profile.environment {
            if let token = env.setEnvToken {
                args += ["-o", "SetEnv=\(token)"]
            }
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

        // Destination (must come last, before any remote command).
        let host = profile.host.trimmingCharacters(in: .whitespaces)
        let user = profile.username.trimmingCharacters(in: .whitespaces)
        let dest = user.isEmpty ? host : "\(user)@\(host)"
        if !dest.isEmpty {
            args.append(dest)
        }
        // A remote command is passed as a single argument after the destination.
        if hasRemoteCommand {
            args.append(remoteCommand)
        }
        return args
    }

    /// A human-readable, copy-pasteable command preview (with simple shell quoting).
    static func commandPreview(for profile: SSHProfile) -> String {
        (["ssh"] + arguments(for: profile)).map(shellQuote).joined(separator: " ")
    }

    /// The `[user@]host` destination for a profile (used by control commands).
    static func destination(for profile: SSHProfile) -> String {
        let host = profile.host.trimmingCharacters(in: .whitespaces)
        let user = profile.username.trimmingCharacters(in: .whitespaces)
        return user.isEmpty ? host : "\(user)@\(host)"
    }

    /// The ssh forward flag + spec for a single forward (e.g. `-L`,
    /// `127.0.0.1:8080:localhost:80`), or nil when the forward is incomplete.
    /// Shared by the static command builder and live `ssh -O forward`.
    static func forwardOption(_ forward: PortForward) -> (flag: String, spec: String)? {
        let bind = forward.bindAddress.trimmingCharacters(in: .whitespaces)
        let bindPrefix = bind.isEmpty ? "" : "\(bind):"
        switch forward.type {
        case .local, .remote:
            guard !forward.listenPort.isEmpty, !forward.targetPort.isEmpty else { return nil }
            let host = forward.targetHost.isEmpty ? "localhost" : forward.targetHost
            return (forward.type.flag, "\(bindPrefix)\(forward.listenPort):\(host):\(forward.targetPort)")
        case .dynamic:
            guard !forward.listenPort.isEmpty else { return nil }
            return (forward.type.flag, "\(bindPrefix)\(forward.listenPort)")
        }
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

/// Builds the argument list to launch a profile with **mosh** (mobile shell)
/// instead of plain ssh. mosh keeps a session alive across network changes and
/// sleeps; it doesn't set up port forwards, so those are left to a normal ssh
/// connection. Pure string-building, mirroring `SSHCommandBuilder`.
enum MoshCommandBuilder {
    /// Common install locations for the `mosh` client (Homebrew first).
    static let candidatePaths = [
        "/opt/homebrew/bin/mosh",
        "/usr/local/bin/mosh",
        "/usr/bin/mosh",
    ]

    /// The first mosh client that exists on disk, else `mosh` (resolved via PATH).
    static var executablePath: String {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "mosh"
    }

    /// Whether a mosh client is installed in one of the known locations.
    static var isAvailable: Bool {
        candidatePaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The ssh sub-command mosh uses to log in, as one `--ssh=` string value.
    private static func sshSubcommand(for profile: SSHProfile) -> String {
        var parts = ["ssh"]
        if let port = Int(profile.port.trimmingCharacters(in: .whitespaces)), port != 22 {
            parts += ["-p", "\(port)"]
        }
        let identity = profile.identityFile.trimmingCharacters(in: .whitespaces)
        if !identity.isEmpty { parts += ["-i", SSHCommandBuilder.expandPath(identity)] }
        let jump = profile.jumpHost.trimmingCharacters(in: .whitespaces)
        if !jump.isEmpty { parts += ["-J", jump] }
        if let value = profile.strictHostKeyChecking.optionValue {
            parts += ["-o", "StrictHostKeyChecking=\(value)"]
        }
        if profile.connectTimeout > 0 { parts += ["-o", "ConnectTimeout=\(profile.connectTimeout)"] }
        return parts.joined(separator: " ")
    }

    static func arguments(for profile: SSHProfile) -> [String] {
        var args: [String] = []
        let sub = sshSubcommand(for: profile)
        if sub != "ssh" { args.append("--ssh=\(sub)") }
        let host = profile.host.trimmingCharacters(in: .whitespaces)
        let user = profile.username.trimmingCharacters(in: .whitespaces)
        args.append(user.isEmpty ? host : "\(user)@\(host)")
        let remote = profile.remoteCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remote.isEmpty { args += ["--", remote] }
        return args
    }

    static func commandPreview(for profile: SSHProfile) -> String {
        ([executablePath] + arguments(for: profile))
            .map(SSHCommandBuilder.shellQuote).joined(separator: " ")
    }
}
