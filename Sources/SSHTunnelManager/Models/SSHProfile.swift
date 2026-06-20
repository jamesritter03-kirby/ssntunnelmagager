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

/// What a (local) port forward exposes, so the app can offer a matching
/// "Open" action that launches the right kind of tab against the forwarded
/// local port. Purely a convenience layer over a normal `-L` forward — it does
/// not change the `ssh` command at all.
enum ForwardCategory: String, Codable, CaseIterable, Identifiable {
    case none
    case webpage
    case mqtt
    case redis

    var id: String { rawValue }

    /// Menu / picker label.
    var title: String {
        switch self {
        case .none:    return "None"
        case .webpage: return "Web Page"
        case .mqtt:    return "MQTT"
        case .redis:   return "Redis"
        }
    }

    /// SF Symbol used in pickers, launchers and (for mqtt/redis) the tab itself.
    var symbol: String {
        switch self {
        case .none:    return "minus.circle"
        case .webpage: return "globe"
        case .mqtt:    return "antenna.radiowaves.left.and.right"
        case .redis:   return "cylinder.split.1x2"
        }
    }

    /// Whether this category can launch a tab (everything but `.none`).
    var isLaunchable: Bool { self != .none }

    /// The conventional default port for this service, used to prefill the
    /// ad-hoc “new connection” form.
    var defaultPort: Int {
        switch self {
        case .webpage: return 8080
        case .mqtt:    return 1883
        case .redis:   return 6379
        case .none:    return 0
        }
    }

    /// The terminal-tab kind a launchable service opens, when it's a CLI client
    /// (mqtt / redis). `.webpage` opens a browser tab instead, so it's nil here.
    var terminalKind: TerminalSession.Kind? {
        switch self {
        case .mqtt:  return .mqtt
        case .redis: return .redis
        default:     return nil
        }
    }
}

/// A single port-forwarding rule.
struct PortForward: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var type: ForwardType = .local
    /// What the forwarded local port exposes (drives the "Open …" launchers).
    /// Only meaningful for `.local` forwards. `.none` = a plain forward.
    var category: ForwardCategory = .none
    /// Username for a categorized **MQTT / Redis** service, passed to the CLI
    /// client when the tab launches. Not secret, so it lives in the profile; the
    /// matching **password** is stored in the Keychain keyed by this forward's id.
    var serviceUsername: String = ""
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

    /// The address a local client uses to reach this forward. Only `.local`
    /// forwards listen on this Mac, so only they have a local endpoint
    /// (`127.0.0.1:listenPort`, or the chosen bind address).
    var localEndpoint: (host: String, port: Int)? {
        guard type == .local,
              let p = Int(listenPort.trimmingCharacters(in: .whitespaces)), p > 0 else { return nil }
        let bind = bindAddress.trimmingCharacters(in: .whitespaces)
        let host = (bind.isEmpty || bind == "*" || bind == "0.0.0.0") ? "127.0.0.1" : bind
        return (host, p)
    }
}

// A hand-written decoder so profiles saved before `category` existed still load
// (the synthesized one would throw `keyNotFound` on the missing key and, via the
// app's `try?` load, silently drop every saved profile).
extension PortForward {
    enum CodingKeys: String, CodingKey {
        case id, type, category, serviceUsername, bindAddress, listenPort, targetHost, targetPort
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try c.decodeIfPresent(ForwardType.self, forKey: .type) ?? .local
        category = try c.decodeIfPresent(ForwardCategory.self, forKey: .category) ?? .none
        serviceUsername = try c.decodeIfPresent(String.self, forKey: .serviceUsername) ?? ""
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? ""
        listenPort = try c.decodeIfPresent(String.self, forKey: .listenPort) ?? ""
        targetHost = try c.decodeIfPresent(String.self, forKey: .targetHost) ?? "localhost"
        targetPort = try c.decodeIfPresent(String.self, forKey: .targetPort) ?? ""
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
    /// Optional name of the workspace this profile's tabs should open in.
    /// Connecting switches to (or creates) that workspace. Empty = use whatever
    /// workspace is current.
    var workspace: String = ""

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

    /// Local forwards tagged with a launchable service category (Web / MQTT /
    /// Redis) that have a usable local endpoint, in profile order. Drives the
    /// "Open …" service launchers in the sidebar and tab menus.
    var categorizedForwards: [PortForward] {
        forwards.filter { $0.category.isLaunchable && $0.localEndpoint != nil }
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
        case workspace
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
        workspace = try c.decodeIfPresent(String.self, forKey: .workspace) ?? ""
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
