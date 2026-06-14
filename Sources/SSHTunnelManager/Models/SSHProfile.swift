import Foundation

/// The kind of SSH port forwarding.
enum ForwardType: String, Codable, CaseIterable, Identifiable {
    case local
    case remote
    case dynamic

    var id: String { rawValue }

    /// The `ssh` command-line flag for this forward type.
    var flag: String {
        switch self {
        case .local: return "-L"
        case .remote: return "-R"
        case .dynamic: return "-D"
        }
    }

    var title: String {
        switch self {
        case .local: return "Local  ·  -L"
        case .remote: return "Remote  ·  -R"
        case .dynamic: return "Dynamic / SOCKS  ·  -D"
        }
    }

    var explanation: String {
        switch self {
        case .local:
            return "Opens a port on THIS Mac and forwards it through the server to a target reachable from the server. (e.g. reach a remote database locally)"
        case .remote:
            return "Opens a port on the SERVER and forwards it back to a target reachable from this Mac. (e.g. expose a local service to the server)"
        case .dynamic:
            return "Runs a SOCKS proxy on this Mac; apps pointed at it route their traffic through the server."
        }
    }
}

/// A single port-forwarding rule.
struct PortForward: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var type: ForwardType = .local
    /// Optional bind address for the listening side (e.g. 127.0.0.1, 0.0.0.0, *). Empty = ssh default.
    var bindAddress: String = ""
    /// The port that is opened / listened on (local side for -L and -D, remote side for -R).
    var listenPort: String = ""
    /// The destination host (used by -L and -R, ignored by -D).
    var targetHost: String = "localhost"
    /// The destination port (used by -L and -R, ignored by -D).
    var targetPort: String = ""

    /// Short one-line description for list rows.
    var summary: String {
        let lp = listenPort.isEmpty ? "?" : listenPort
        switch type {
        case .dynamic:
            return "SOCKS :\(lp)"
        case .local:
            return ":\(lp) → \(targetHost):\(targetPort.isEmpty ? "?" : targetPort)"
        case .remote:
            return "srv:\(lp) → \(targetHost):\(targetPort.isEmpty ? "?" : targetPort)"
        }
    }
}

/// A reusable, named command the user can insert into a session's terminal.
struct CommandSnippet: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var label: String = ""
    var command: String = ""
}

/// A saved SSH connection + tunnel configuration.
struct SSHProfile: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = "New Profile"
    var host: String = ""
    var port: String = "22"
    var username: String = ""
    /// Path to a private key file (optional). Supports `~` expansion.
    var identityFile: String = ""
    var forwards: [PortForward] = []
    /// When true, open an interactive shell in addition to the tunnels.
    /// When false, pass `-N` (no remote command; tunnels only).
    var openShell: Bool = true
    var compression: Bool = false
    var keepAlive: Bool = true
    var verbose: Bool = false
    /// Optional ProxyJump host (`-J`), e.g. `user@bastion`.
    var jumpHost: String = ""
    /// Extra raw ssh options appended verbatim, e.g. `-o StrictHostKeyChecking=accept-new`.
    var extraOptions: String = ""
    /// The terminal color theme id (see `TerminalTheme`).
    var theme: String = TerminalTheme.defaultID
    /// Commonly used commands the user can insert into the session's terminal.
    var snippets: [CommandSnippet] = []
    /// Require Touch ID / login password before using the Keychain-stored password.
    var requireAuthForSavedPassword: Bool = true

    /// `user@host` style subtitle for list rows.
    var subtitle: String {
        let user = username.isEmpty ? "" : "\(username)@"
        let h = host.isEmpty ? "—" : host
        let p = (port.isEmpty || port == "22") ? "" : ":\(port)"
        return "\(user)\(h)\(p)"
    }
}

// Defining `init(from:)` in an extension keeps the synthesized memberwise
// initializer, while letting us tolerate older JSON that lacks newer keys.
extension SSHProfile {
    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, identityFile, forwards, openShell
        case compression, keepAlive, verbose, jumpHost, extraOptions, theme, snippets
        case requireAuthForSavedPassword
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "New Profile"
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(String.self, forKey: .port) ?? "22"
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile) ?? ""
        forwards = try c.decodeIfPresent([PortForward].self, forKey: .forwards) ?? []
        openShell = try c.decodeIfPresent(Bool.self, forKey: .openShell) ?? true
        compression = try c.decodeIfPresent(Bool.self, forKey: .compression) ?? false
        keepAlive = try c.decodeIfPresent(Bool.self, forKey: .keepAlive) ?? true
        verbose = try c.decodeIfPresent(Bool.self, forKey: .verbose) ?? false
        jumpHost = try c.decodeIfPresent(String.self, forKey: .jumpHost) ?? ""
        extraOptions = try c.decodeIfPresent(String.self, forKey: .extraOptions) ?? ""
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? TerminalTheme.defaultID
        snippets = try c.decodeIfPresent([CommandSnippet].self, forKey: .snippets) ?? []
        requireAuthForSavedPassword = try c.decodeIfPresent(Bool.self, forKey: .requireAuthForSavedPassword) ?? true
    }
}
