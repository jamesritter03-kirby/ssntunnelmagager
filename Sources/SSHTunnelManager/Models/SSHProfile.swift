import Foundation

/// Shared limits for the terminal text size (points). Used by profiles, the
/// local-terminal default, and the ⌘+/⌘− zoom commands.
enum TerminalFontMetrics {
    static let `default`: Double = 13
    static let min: Double = 8
    static let max: Double = 36
    static let step: Double = 1

    /// Keep a size within the allowed range (and rounded to a whole point).
    static func clamp(_ size: Double) -> Double {
        Swift.min(max, Swift.max(min, (size).rounded()))
    }
}

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

/// A saved web link the user can open in an in-app browser tab. Handy for the
/// web UI a tunnel exposes (e.g. `localhost:8080`) or any related page.
struct ProfileLink: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var label: String = ""
    var url: String = ""

    /// The label to show, falling back to the URL when no label is set.
    var displayLabel: String {
        let l = label.trimmingCharacters(in: .whitespaces)
        return l.isEmpty ? url.trimmingCharacters(in: .whitespaces) : l
    }

    /// A best-effort `URL`, adding a scheme when the user omitted one. Local
    /// hosts / bare IPs default to `http://` (typical for tunneled dev UIs);
    /// everything else defaults to `https://`.
    var normalizedURL: URL? {
        var s = url.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") {
            let lower = s.lowercased()
            let looksLocal = lower.hasPrefix("localhost")
                || lower.range(of: #"^\d{1,3}(\.\d{1,3}){3}"#, options: .regularExpression) != nil
            s = (looksLocal ? "http://" : "https://") + s
        }
        return URL(string: s)
    }
}

/// A saved SSH connection + tunnel configuration.
struct SSHProfile: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = "New Profile"
    /// An SF Symbol name chosen for this profile (empty = a sensible default
    /// based on whether it's local). See `displayIcon` and `ProfileIcon`.
    var icon: String = ""
    /// When true this is a **local shell** profile (no SSH): it opens the login
    /// shell in a new tab, starting in `startPath`. All SSH-related fields below
    /// are ignored.
    var isLocal: Bool = false
    /// For local profiles: the folder the shell starts in (supports `~`). Empty
    /// means the default working directory (home).
    var startPath: String = ""
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
    /// The terminal text size in points (adjustable live with ⌘+ / ⌘−).
    var fontSize: Double = TerminalFontMetrics.default
    /// Commonly used commands the user can insert into the session's terminal.
    var snippets: [CommandSnippet] = []
    /// Saved web links openable in an in-app browser tab.
    var links: [ProfileLink] = []
    /// Require Touch ID / login password before using the Keychain-stored password.
    var requireAuthForSavedPassword: Bool = true

    /// `user@host` style subtitle for list rows.
    var subtitle: String {
        let user = username.isEmpty ? "" : "\(username)@"
        let h = host.isEmpty ? "—" : host
        let p = (port.isEmpty || port == "22") ? "" : ":\(port)"
        return "\(user)\(h)\(p)"
    }

    /// Subtitle shown in the sidebar / palette — local profiles show their start
    /// folder instead of a host.
    var rowSubtitle: String {
        guard isLocal else { return subtitle }
        let p = startPath.trimmingCharacters(in: .whitespaces)
        if p.isEmpty { return "Local shell" }
        let home = NSHomeDirectory()
        let shown = p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p[...]
        return "Local · \(shown)"
    }

    /// The SF Symbol shown for this profile in the sidebar, editor and palette.
    /// Falls back to a sensible default when the user hasn't picked one.
    var displayIcon: String {
        let chosen = icon.trimmingCharacters(in: .whitespaces)
        if !chosen.isEmpty { return chosen }
        return isLocal ? "terminal" : "point.3.connected.trianglepath.dotted"
    }

    /// The local endpoint of this profile's first dynamic (SOCKS / `-D`) forward,
    /// if any. A web tab opened from this profile routes its traffic through it.
    var socksProxy: (host: String, port: Int)? {
        guard let dyn = forwards.first(where: { $0.type == .dynamic }),
              let port = Int(dyn.listenPort.trimmingCharacters(in: .whitespaces)) else { return nil }
        let bind = dyn.bindAddress.trimmingCharacters(in: .whitespaces)
        return (bind.isEmpty ? "127.0.0.1" : bind, port)
    }
}

// Defining `init(from:)` in an extension keeps the synthesized memberwise
// initializer, while letting us tolerate older JSON that lacks newer keys.
extension SSHProfile {
    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, identityFile, forwards, openShell
        case compression, keepAlive, verbose, jumpHost, extraOptions, theme, snippets
        case requireAuthForSavedPassword
        case fontSize
        case isLocal, startPath, icon
        case links
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "New Profile"
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? ""
        isLocal = try c.decodeIfPresent(Bool.self, forKey: .isLocal) ?? false
        startPath = try c.decodeIfPresent(String.self, forKey: .startPath) ?? ""
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
        links = try c.decodeIfPresent([ProfileLink].self, forKey: .links) ?? []
        requireAuthForSavedPassword = try c.decodeIfPresent(Bool.self, forKey: .requireAuthForSavedPassword) ?? true
        fontSize = TerminalFontMetrics.clamp(try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? TerminalFontMetrics.default)
    }
}

/// Curated SF Symbols offered by the profile icon picker, grouped for display.
enum ProfileIcon {
    static let groups: [(name: String, symbols: [String])] = [
        ("Servers & Network", [
            "point.3.connected.trianglepath.dotted", "server.rack", "network",
            "externaldrive.connected.to.line.below", "cloud", "globe",
            "antenna.radiowaves.left.and.right", "wifi",
        ]),
        ("Devices", [
            "desktopcomputer", "laptopcomputer", "pc", "display",
            "terminal", "macpro.gen3", "tv", "gamecontroller",
        ]),
        ("Storage & Data", [
            "internaldrive", "externaldrive", "cylinder.split.1x2", "tray.full",
            "folder", "shippingbox", "archivebox", "tablecells",
        ]),
        ("Security", [
            "lock.shield", "key", "key.fill", "checkmark.shield", "lock", "hand.raised",
        ]),
        ("Tags & Symbols", [
            "star", "bolt", "flame", "leaf", "heart", "flag",
            "tag", "bookmark", "house", "building.2", "person.crop.circle",
            "gearshape", "hammer", "wrench.and.screwdriver", "ladybug", "cube",
        ]),
    ]

    /// Every symbol, flattened (used for validation / tests).
    static let allSymbols: [String] = groups.flatMap(\.symbols)
}
