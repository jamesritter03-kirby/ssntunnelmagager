import Foundation

/// Builds the `ssh` argument list (and a human-readable preview) for a **VNC over
/// SSH** session: a tunnels-only `ssh -N` that opens a local port-forward to the
/// server's VNC port, so macOS Screen Sharing can connect to the remote desktop
/// through an encrypted SSH tunnel.
///
/// VNC traffic is normally unencrypted; routing it through SSH (the whole point
/// of this app) keeps the screen session private and reuses the profile's host,
/// key and saved password.
enum VNCCommandBuilder {
    static let sshPath = SSHCommandBuilder.sshPath

    /// The standard VNC / Apple Screen Sharing port on the remote host.
    static let defaultRemotePort = 5900
    /// Connect to the server's *own* screen by default (its loopback address).
    static let defaultRemoteHost = "127.0.0.1"

    /// Build the `ssh` arguments for a VNC tunnel: forward `localPort` on this Mac
    /// to `remoteHost:remotePort` as seen from the server. `-v` is included so the
    /// driver can detect when the forward is listening; `-N` runs tunnels only.
    static func arguments(for profile: SSHProfile,
                          localPort: Int,
                          remoteHost: String = defaultRemoteHost,
                          remotePort: Int = defaultRemotePort) -> [String] {
        var args: [String] = ["-N", "-v"]

        if profile.compression { args.append("-C") }
        if profile.keepAlive {
            args += ["-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3"]
        }
        // Fail fast (and report) if the local listener can't be opened.
        args += ["-o", "ExitOnForwardFailure=yes"]

        if let port = Int(profile.port.trimmingCharacters(in: .whitespaces)), port != 22 {
            args += ["-p", "\(port)"]
        }
        let identity = profile.identityFile.trimmingCharacters(in: .whitespaces)
        if !identity.isEmpty {
            args += ["-i", SSHCommandBuilder.expandPath(identity)]
        }
        let jump = profile.jumpHost.trimmingCharacters(in: .whitespaces)
        if !jump.isEmpty {
            args += ["-J", jump]
        }

        // Extra raw options, naive whitespace split (matches SSHCommandBuilder).
        let extra = profile.extraOptions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            args += extra.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        }

        // The VNC port-forward.
        args += ["-L", "\(localPort):\(remoteHost):\(remotePort)"]

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
    static func commandPreview(for profile: SSHProfile,
                               localPort: Int,
                               remoteHost: String = defaultRemoteHost,
                               remotePort: Int = defaultRemotePort) -> String {
        (["ssh"] + arguments(for: profile, localPort: localPort,
                             remoteHost: remoteHost, remotePort: remotePort))
            .map(SSHCommandBuilder.shellQuote)
            .joined(separator: " ")
    }

    /// Ask the OS for a free TCP port on loopback by binding to port 0 and reading
    /// back the assigned port. Falls back to a value in the dynamic range if the
    /// socket call fails. There's a tiny window before `ssh` re-binds it, but in
    /// practice ssh claims the port immediately.
    static func freeLocalPort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd >= 0 {
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bound == 0 {
                var out = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let got = withUnsafeMutablePointer(to: &out) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getsockname(fd, $0, &len)
                    }
                }
                if got == 0 {
                    let port = Int(UInt16(bigEndian: out.sin_port))
                    if port > 0 { return port }
                }
            }
        }
        return Int.random(in: 50000...59999)
    }

    /// Parse a `-L local:host:port` forward spec out of an `ssh` argument list.
    /// Used by `VNCClient` so the session's chosen port/target can be displayed
    /// without threading extra state through `TerminalSession`.
    static func parseForward(in args: [String]) -> (localPort: Int, remoteHost: String, remotePort: Int)? {
        guard let i = args.firstIndex(of: "-L"), i + 1 < args.count else { return nil }
        let parts = args[i + 1].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let local = Int(parts[0]),
              let remote = Int(parts[2]) else { return nil }
        return (local, parts[1], remote)
    }
}
