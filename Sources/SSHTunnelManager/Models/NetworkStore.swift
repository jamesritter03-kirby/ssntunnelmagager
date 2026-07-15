import Foundation

/// A network interface on this Mac, as reported by the system tools.
struct MacInterface: Identifiable, Hashable {
    let bsdName: String            // e.g. "en0"
    var friendlyName: String       // e.g. "Wi-Fi"
    var isUp: Bool
    var ipv4: [String]
    var ipv6: [String]
    var macAddress: String?
    var mediaType: String?         // e.g. "Wi-Fi", "Ethernet"

    var id: String { bsdName }

    /// The first IPv4 address, if any (the one most people care about).
    var primaryIPv4: String? { ipv4.first }

    /// A short one-line summary for a row subtitle.
    var subtitle: String {
        if let ip = primaryIPv4 { return "\(bsdName) · \(ip)" }
        if !ipv6.isEmpty { return "\(bsdName) · \(ipv6.first!)" }
        return bsdName
    }
}

/// Live Wi-Fi details for the Mac's active wireless interface.
struct WiFiInfo: Hashable {
    var ssid: String?
    var bssid: String?
    var rssi: Int?                 // dBm
    var noise: Int?               // dBm
    var txRate: Double?           // Mbps
    var channel: String?

    /// Signal quality 0–100 derived from RSSI (roughly -100 dBm = 0, -50 = 100).
    var signalPercent: Int? {
        guard let rssi else { return nil }
        let clamped = max(-100, min(-50, rssi))
        return Int(Double(clamped + 100) / 50.0 * 100.0)
    }
}

/// The current Internet Sharing (ICS) configuration on this Mac, read from
/// `/Library/Preferences/SystemConfiguration/com.apple.nat.plist`. ICS shares
/// one interface's internet connection (`sourceDevice`) out over one or more
/// other interfaces (`toDevices`), NAT'ing between them.
struct InternetSharingState: Hashable {
    /// Whether Internet Sharing is enabled in the saved config.
    var isEnabled = false
    /// BSD name of the interface whose connection is shared (the uplink), e.g.
    /// "en0". Empty when unset.
    var sourceDevice = ""
    /// BSD names of the interfaces the connection is shared out over.
    var toDevices: [String] = []
    /// Whether the InternetSharing daemon is actually running right now.
    var isRunning = false
}

/// A user-defined "Mac as router" configuration: the Mac assigns itself a fixed
/// LAN IP, NATs a LAN interface's traffic out over an uplink, and runs a DHCP
/// server for the LAN subnet. Unlike macOS's built-in Internet Sharing (fixed
/// 192.168.2.0/24), this lets the user pick the whole subnet and DHCP range.
struct MacRouterConfig: Codable, Hashable {
    /// The uplink interface with internet access (e.g. Wi-Fi "en0").
    var uplinkDevice = ""
    /// The LAN interface the Mac routes for (e.g. a USB Ethernet "en7").
    var lanDevice = ""
    /// The Mac's address on the LAN — it acts as the gateway (e.g. "10.1.1.1").
    var routerIP = "10.1.1.1"
    /// The LAN subnet mask.
    var subnetMask = "255.255.255.0"
    /// Whether the built-in DHCP server hands out addresses.
    var dhcpEnabled = true
    /// First address of the DHCP pool.
    var dhcpStart = "10.1.1.100"
    /// Last address of the DHCP pool.
    var dhcpEnd = "10.1.1.200"
    /// DHCP lease length in seconds.
    var leaseSeconds = 86_400
    /// Whether to bring the router up automatically when the app launches.
    var autoStart = false
    /// Whether to host the router status/config web portal on port 80.
    var webPortalEnabled = true

    /// The LAN network address derived from routerIP + mask (e.g. "10.1.1.0").
    var networkAddress: String {
        let ip = routerIP.split(separator: ".").compactMap { UInt32($0) }
        let mk = subnetMask.split(separator: ".").compactMap { UInt32($0) }
        guard ip.count == 4, mk.count == 4 else { return routerIP }
        let net = (0..<4).map { ip[$0] & mk[$0] }
        return net.map(String.init).joined(separator: ".")
    }

    /// CIDR prefix length from the dotted mask (e.g. 255.255.255.0 → 24).
    var prefixLength: Int {
        subnetMask.split(separator: ".").compactMap { UInt8($0) }
            .reduce(0) { $0 + $1.nonzeroBitCount }
    }

    init() {}

    // Custom decoding so newly-added fields (e.g. `webPortalEnabled`) don't cause
    // a decode failure on configs saved by older builds — missing keys fall back
    // to their defaults instead of wiping the whole saved configuration.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let def = MacRouterConfig()
        uplinkDevice = try c.decodeIfPresent(String.self, forKey: .uplinkDevice) ?? def.uplinkDevice
        lanDevice = try c.decodeIfPresent(String.self, forKey: .lanDevice) ?? def.lanDevice
        routerIP = try c.decodeIfPresent(String.self, forKey: .routerIP) ?? def.routerIP
        subnetMask = try c.decodeIfPresent(String.self, forKey: .subnetMask) ?? def.subnetMask
        dhcpEnabled = try c.decodeIfPresent(Bool.self, forKey: .dhcpEnabled) ?? def.dhcpEnabled
        dhcpStart = try c.decodeIfPresent(String.self, forKey: .dhcpStart) ?? def.dhcpStart
        dhcpEnd = try c.decodeIfPresent(String.self, forKey: .dhcpEnd) ?? def.dhcpEnd
        leaseSeconds = try c.decodeIfPresent(Int.self, forKey: .leaseSeconds) ?? def.leaseSeconds
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? def.autoStart
        webPortalEnabled = try c.decodeIfPresent(Bool.self, forKey: .webPortalEnabled) ?? def.webPortalEnabled
    }
}

/// A device seen on the Mac's router LAN — from the DHCP lease file and/or the
/// live ARP table.
struct RouterClient: Identifiable, Hashable {
    var ip: String
    var mac: String
    var hostName: String?
    /// Whether the device is currently in the ARP table (recently reachable).
    var isActive: Bool
    var id: String { mac.isEmpty ? ip : mac }

    var displayName: String {
        if let h = hostName, !h.isEmpty, h != "?" { return h }
        return ip
    }
}

/// Gathers this Mac's live network state (interfaces, gateway, DNS, Wi-Fi,
/// public IP) by shelling out to the standard macOS network tools, and exposes
/// a few common maintenance actions (flush DNS, renew DHCP). A singleton so the
/// Network browser and any menu actions share one cache.
@MainActor
final class NetworkStore: ObservableObject {
    static let shared = NetworkStore()
    private init() {
        routerConfig = Self.loadRouterConfig()
    }
    @Published private(set) var interfaces: [MacInterface] = []
    @Published private(set) var defaultGateway: String?
    @Published private(set) var dnsServers: [String] = []
    @Published private(set) var wifi: WiFiInfo?
    @Published private(set) var publicIP: String?
    @Published private(set) var hostName: String = Host.current().localizedName ?? "This Mac"
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshed: Date?
    @Published var lastActionMessage: String?

    /// Current Internet Sharing (ICS) configuration read from the system.
    @Published private(set) var sharing = InternetSharingState()

    /// The primary network service name (e.g. "Wi-Fi", "Ethernet") that DNS /
    /// gateway edits target — the top active service in the service order.
    @Published private(set) var primaryService: String?

    /// The user's "Mac as router" configuration (persisted to UserDefaults).
    @Published var routerConfig: MacRouterConfig {
        didSet { Self.saveRouterConfig(routerConfig) }
    }
    /// Whether our custom router is currently active (LAN IP assigned + NAT up).
    @Published private(set) var routerRunning = false {
        didSet {
            guard routerRunning != oldValue else { return }
            if routerRunning { startRouterClientPolling() }
            else { stopRouterClientPolling() }
        }
    }
    /// Devices seen on the router LAN (DHCP leases merged with the ARP table).
    @Published private(set) var routerClients: [RouterClient] = []
    /// True while an enable/disable router action is in flight.
    @Published private(set) var routerBusy = false
    /// Background task that keeps `routerClients` fresh while the router is up,
    /// so live status glyphs (green globes) stay accurate.
    private var routerClientPoll: Task<Void, Never>?

    private func startRouterClientPolling() {
        routerClientPoll?.cancel()
        routerClientPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshRouterClients()
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            }
        }
    }

    private func stopRouterClientPolling() {
        routerClientPoll?.cancel()
        routerClientPoll = nil
    }

    // MARK: Refresh

    /// Reload every piece of local network state. Public-IP lookup runs in
    /// parallel (it hits the network) while the rest reads local tools.
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        async let ifaces = Self.readInterfaces()
        async let gw = Self.readDefaultGateway()
        async let dns = Self.readDNSServers()
        async let wifiInfo = Self.readWiFi()
        async let pub = Self.fetchPublicIP()
        async let share = Self.readSharing()

        let (i, g, d, w, p) = await (ifaces, gw, dns, wifiInfo, pub)
        interfaces = i
        defaultGateway = g
        dnsServers = d
        wifi = w
        publicIP = p
        sharing = await share
        primaryService = await Self.readPrimaryService()
        routerRunning = await Self.readRouterRunning(config: routerConfig)
        if routerRunning {
            routerClients = await Self.readRouterClients(config: routerConfig)
        } else {
            routerClients = []
        }
        lastRefreshed = Date()
    }

    /// Refresh only the public IP (network round-trip), leaving local state.
    func refreshPublicIP() async {
        publicIP = await Self.fetchPublicIP()
    }

    // MARK: Actions

    /// Flush the macOS DNS cache (requires an admin prompt via osascript).
    func flushDNS() async {
        let script = "do shell script \"dscacheutil -flushcache; killall -HUP mDNSResponder\" with administrator privileges"
        let ok = await Self.runOSAScript(script)
        lastActionMessage = ok ? "Flushed the DNS cache." : "Couldn’t flush the DNS cache."
    }

    /// Renew the DHCP lease on an interface (admin prompt).
    func renewDHCP(_ bsdName: String) async {
        let script = "do shell script \"ipconfig set \(bsdName) DHCP\" with administrator privileges"
        let ok = await Self.runOSAScript(script)
        lastActionMessage = ok ? "Renewed DHCP on \(bsdName)." : "Couldn’t renew DHCP on \(bsdName)."
        await refresh()
    }

    // MARK: Internet Sharing

    /// Configure and start Internet Sharing: share `source`'s connection out over
    /// `toDevices`. Writes the NAT config and (re)starts the InternetSharing
    /// daemon, all under a single admin prompt. Returns after refreshing state.
    func enableSharing(source: String, toDevices: [String]) async {
        guard !source.isEmpty, !toDevices.isEmpty else {
            lastActionMessage = "Pick a source connection and at least one interface to share to."
            return
        }
        let ok = await Self.applySharing(enabled: true, source: source, toDevices: toDevices)
        lastActionMessage = ok
            ? "Internet Sharing started from \(source)."
            : "Couldn’t start Internet Sharing (cancelled or failed)."
        await refresh()
    }

    /// Turn Internet Sharing off and stop the daemon (admin prompt).
    func disableSharing() async {
        let ok = await Self.applySharing(enabled: false,
                                         source: sharing.sourceDevice,
                                         toDevices: sharing.toDevices)
        lastActionMessage = ok ? "Internet Sharing stopped." : "Couldn’t stop Internet Sharing."
        await refresh()
    }

    // MARK: Mac as Router

    /// When the pre-flight check finds another device already using the chosen
    /// router IP, this holds a human-readable description of it. The UI shows a
    /// confirmation so the user can cancel (recommended) or start anyway.
    @Published var routerIPConflict: String?

    /// Bring up the custom router described by `routerConfig`: assign the LAN IP,
    /// enable IP forwarding, install a pf NAT rule out the uplink, and (if
    /// enabled) start the bootpd DHCP server. One admin prompt for everything.
    ///
    /// Before touching anything it probes the chosen router IP; if some other
    /// device on the LAN already answers there, it stops and populates
    /// `routerIPConflict` instead (unless `force` is true).
    func enableRouter(force: Bool = false) async {
        let cfg = routerConfig
        guard !cfg.uplinkDevice.isEmpty, !cfg.lanDevice.isEmpty else {
            lastActionMessage = "Pick an uplink (internet) interface and a LAN interface."
            return
        }
        guard cfg.uplinkDevice != cfg.lanDevice else {
            lastActionMessage = "The uplink and LAN interfaces must be different."
            return
        }
        guard isValidIPv4(cfg.routerIP), isValidIPv4(cfg.subnetMask) else {
            lastActionMessage = "Enter a valid router IP and subnet mask."
            return
        }

        // Pre-flight: is someone else already using our router IP on the LAN?
        if !force {
            routerBusy = true
            let conflict = await Self.detectIPConflict(ip: cfg.routerIP, device: cfg.lanDevice)
            routerBusy = false
            if let conflict {
                routerIPConflict = conflict
                return
            }
        }

        routerBusy = true
        let ok = await Self.applyRouter(enabled: true, config: cfg)
        routerBusy = false
        lastActionMessage = ok
            ? "Router started — \(cfg.routerIP) on \(cfg.lanDevice), sharing \(cfg.uplinkDevice)."
            : "Couldn’t start the router (cancelled or failed)."
        await refresh()
    }

    /// Tear the custom router down: stop DHCP, remove the pf NAT rule, drop the
    /// LAN IP, and disable forwarding (admin prompt).
    func disableRouter() async {
        routerBusy = true
        let ok = await Self.applyRouter(enabled: false, config: routerConfig)
        routerBusy = false
        lastActionMessage = ok ? "Router stopped." : "Couldn’t stop the router."
        await refresh()
    }

    /// Reload just the list of devices on the router LAN.
    func refreshRouterClients() async {
        guard routerRunning else { routerClients = []; return }
        routerClients = await Self.readRouterClients(config: routerConfig)
        // Keep the web portal's data file in sync, and pick up any config change
        // submitted through the portal.
        if routerConfig.webPortalEnabled {
            Self.writeWebData(config: routerConfig, clients: routerClients,
                              dns: routerConfig.routerIP)
            await applyWebConfigRequestIfNeeded()
        }
    }

    /// If the web portal wrote a pending config change, apply it: update the
    /// stored config and restart the router (which prompts for admin once).
    private func applyWebConfigRequestIfNeeded() async {
        guard !routerBusy,
              let newCfg = Self.consumeWebConfigRequest(base: routerConfig) else { return }
        guard newCfg != routerConfig else { return }
        routerConfig = newCfg
        // Note shown on the portal after the restart completes.
        Self.writeWebData(config: newCfg, clients: routerClients,
                          dns: newCfg.routerIP,
                          savedNote: "Applying changes… the router is restarting.")
        await enableRouter(force: true)
    }

    /// Flush the entire ARP cache (admin prompt), then refresh the device list.
    /// Useful when a device's IP↔MAC mapping is stale (e.g. after swapping
    /// hardware or reassigning addresses on the LAN).
    func clearARPCache() async {
        routerBusy = true
        let ok = await Self.runOSAScript(
            "do shell script \"/usr/sbin/arp -a -d\" with administrator privileges")
        routerBusy = false
        lastActionMessage = ok ? "Cleared the ARP cache." : "Couldn’t clear the ARP cache."
        await refreshRouterClients()
    }

    /// Look up a connected Mac-router client by its IP address (if the router is
    /// running). Used to show a live status indicator next to profiles that
    /// connect to a device on the Mac's own LAN.
    func routerClient(forIP ip: String) -> RouterClient? {
        guard routerRunning else { return nil }
        let target = ip.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        return routerClients.first { $0.ip == target }
    }

    /// If auto-start is enabled and the router isn't already up, bring it up.
    /// Called shortly after app launch. Prompts for an admin password (once).
    func autoStartRouterIfNeeded() async {
        guard routerConfig.autoStart else { return }
        guard !routerConfig.uplinkDevice.isEmpty, !routerConfig.lanDevice.isEmpty else { return }
        let running = await Self.readRouterRunning(config: routerConfig)
        if running {
            routerRunning = true
            routerClients = await Self.readRouterClients(config: routerConfig)
            return
        }
        await enableRouter()
        // Wait for the LAN interface to actually hold its address before anything
        // (e.g. auto-connect SSH tabs) tries to use the new subnet — otherwise the
        // first connections fail with "Can't assign requested address".
        await Self.waitForRouterReady(config: routerConfig)
    }

    /// Poll until the LAN interface has the configured router IP (or a timeout).
    /// Used to gate launch-time actions on the router being fully up.
    nonisolated static func waitForRouterReady(config: MacRouterConfig,
                                               timeout: TimeInterval = 8) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await readRouterRunning(config: config) { return }
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
        }
    }

    private func isValidIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            if let n = Int(p), (0...255).contains(n), String(n) == p || p == "0" { return true }
            return Int(p) != nil && (0...255).contains(Int(p)!)
        }
    }

    // MARK: DNS & Gateway editing

    /// Set the DNS servers for a network service (admin prompt). Pass an empty
    /// list to clear back to DHCP-provided servers. `service` defaults to the
    /// primary service.
    func setDNSServers(_ servers: [String], service: String? = nil) async {
        guard let svc = service ?? primaryService else {
            lastActionMessage = "Couldn’t find a network service to update."
            return
        }
        let cleaned = servers
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // networksetup uses the literal "Empty" to clear DNS back to DHCP.
        let arg = cleaned.isEmpty ? "Empty" : cleaned.joined(separator: " ")
        let script = "do shell script \"/usr/sbin/networksetup -setdnsservers '\(svc)' \(arg)\" with administrator privileges"
        let ok = await Self.runOSAScript(script)
        lastActionMessage = ok
            ? (cleaned.isEmpty ? "Reset DNS to DHCP on \(svc)." : "Updated DNS on \(svc).")
            : "Couldn’t update DNS on \(svc)."
        // Flush so the change takes effect immediately.
        if ok { _ = await Self.runOSAScript("do shell script \"dscacheutil -flushcache; killall -HUP mDNSResponder\" with administrator privileges") }
        await refresh()
    }

    /// Change the default gateway (router). This takes effect immediately via the
    /// routing table; with DHCP it reverts on the next lease renewal, so it's best
    /// for temporary overrides. `service`/`ip`/`mask` let it persist by writing a
    /// manual IPv4 config when all are supplied.
    func setGateway(_ gateway: String, persistOn service: String? = nil, ip: String? = nil, mask: String? = nil) async {
        let gw = gateway.trimmingCharacters(in: .whitespaces)
        guard !gw.isEmpty else { lastActionMessage = "Enter a gateway address."; return }

        if let service = service ?? primaryService, let ip, let mask,
           !ip.isEmpty, !mask.isEmpty {
            // Persistent: write a manual IPv4 config (IP + mask + router).
            let script = "do shell script \"/usr/sbin/networksetup -setmanual '\(service)' \(ip) \(mask) \(gw)\" with administrator privileges"
            let ok = await Self.runOSAScript(script)
            lastActionMessage = ok ? "Set gateway \(gw) on \(service)." : "Couldn’t set the gateway."
            await refresh()
            return
        }

        // Temporary: change the live default route only.
        let script = "do shell script \"/sbin/route -n change default \(gw)\" with administrator privileges"
        let ok = await Self.runOSAScript(script)
        lastActionMessage = ok
            ? "Gateway changed to \(gw) (until next DHCP renewal)."
            : "Couldn’t change the gateway."
        await refresh()
    }

    // MARK: - Shell helpers (run off the main actor)

    /// Run a tool and return its stdout (empty string on failure). Never throws.
    nonisolated static func output(_ launchPath: String, _ args: [String]) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard FileManager.default.isExecutableFile(atPath: launchPath) else {
                    cont.resume(returning: ""); return
                }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: launchPath)
                proc.arguments = args
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = Pipe()
                do {
                    try proc.run()
                } catch {
                    cont.resume(returning: ""); return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }

    /// Run an AppleScript string (used for admin-privilege actions). Returns true
    /// on success.
    nonisolated static func runOSAScript(_ script: String) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", script]
                proc.standardOutput = Pipe()
                proc.standardError = Pipe()
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    cont.resume(returning: proc.terminationStatus == 0)
                } catch {
                    cont.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Internet Sharing helpers

    private nonisolated static let natPlistPath = "/Library/Preferences/SystemConfiguration/com.apple.nat.plist"

    /// Read the current Internet Sharing config from the NAT plist and whether the
    /// daemon is running. All reads are best-effort and never throw.
    nonisolated static func readSharing() async -> InternetSharingState {
        var state = InternetSharingState()

        // The plist is root-readable only; try a plain read first, and fall back to
        // `defaults` which can read the system domain.
        let raw = await output("/usr/bin/defaults", ["read", "/Library/Preferences/SystemConfiguration/com.apple.nat"])
        if !raw.isEmpty {
            // Enabled flag lives under NAT { Enabled = 1; ... }.
            if let m = raw.range(of: #"Enabled\s*=\s*1"#, options: .regularExpression) {
                _ = m; state.isEnabled = true
            }
            // PrimaryInterface { Device = "en0"; }
            if let dev = firstCapture(in: raw, pattern: #"Device\s*=\s*\"?([A-Za-z0-9]+)\"?"#) {
                state.sourceDevice = dev
            }
            // SharingDevices = ( en7, bridge100 )  — grab the parenthesized list.
            if let list = firstCapture(in: raw, pattern: #"SharingDevices\s*=\s*\(([^)]*)\)"#) {
                state.toDevices = list
                    .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"")) }
                    .filter { !$0.isEmpty }
            }
        }

        // Is the daemon actually loaded/running?
        let running = await output("/bin/launchctl", ["list"])
        if running.contains("com.apple.InternetSharing") || running.contains("com.apple.NetworkSharing") {
            state.isRunning = true
        }
        // bootpd (the shared DHCP server) running is another strong signal.
        if !state.isRunning {
            let ps = await output("/bin/ps", ["-Ao", "comm"])
            if ps.contains("natd") || ps.contains("bootpd") { state.isRunning = state.isEnabled }
        }
        return state
    }

    private nonisolated static func firstCapture(in text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespaces)
    }

    /// The primary (topmost active) network service name, used as the default
    /// target for DNS / gateway edits. Reads `-listnetworkserviceorder` and picks
    /// the first service whose device currently has an IPv4 address.
    nonisolated static func readPrimaryService() async -> String? {
        let order = await output("/usr/sbin/networksetup", ["-listnetworkserviceorder"])
        // Entries look like:
        //   (1) Wi-Fi
        //   (Hardware Port: Wi-Fi, Device: en0)
        var pairs: [(service: String, device: String)] = []
        var pendingService: String?
        for line in order.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let m = firstCapture(in: t, pattern: #"^\(\d+\)\s+(.*)$"#) {
                pendingService = m
            } else if t.hasPrefix("(Hardware Port:"),
                      let dev = firstCapture(in: t, pattern: #"Device:\s*([A-Za-z0-9]+)"#) {
                if let svc = pendingService { pairs.append((svc, dev)) }
                pendingService = nil
            }
        }
        // Prefer the first service whose device has an IPv4 address right now.
        for pair in pairs {
            let info = await output("/usr/sbin/ipconfig", ["getifaddr", pair.device])
            if !info.trimmingCharacters(in: .whitespaces).isEmpty { return pair.service }
        }
        return pairs.first?.service
    }

    /// Write the NAT config and start/stop the InternetSharing daemon under one
    /// admin prompt. Builds a small shell script that writes the plist with
    /// `defaults`/`PlistBuddy` and toggles the launchd service, then runs it with
    /// administrator privileges. Returns true on success.
    nonisolated static func applySharing(enabled: Bool, source: String, toDevices: [String]) async -> Bool {
        let plist = natPlistPath
        let sharingList = toDevices.map { "\"\($0)\"" }.joined(separator: " ")

        // PlistBuddy commands: rebuild the NAT dict from scratch so stale keys
        // don't linger. Devices go into SharingDevices; PrimaryInterface names the
        // uplink; Enabled flips ICS on/off.
        var pb = [
            "/usr/libexec/PlistBuddy -c 'Delete :NAT' \(plist) 2>/dev/null || true",
            "/usr/libexec/PlistBuddy -c 'Add :NAT dict' \(plist)",
            "/usr/libexec/PlistBuddy -c 'Add :NAT:Enabled integer \(enabled ? 1 : 0)' \(plist)",
        ]
        if enabled {
            pb.append("/usr/libexec/PlistBuddy -c 'Add :NAT:PrimaryInterface dict' \(plist)")
            pb.append("/usr/libexec/PlistBuddy -c 'Add :NAT:PrimaryInterface:Device string \(source)' \(plist)")
            pb.append("/usr/libexec/PlistBuddy -c 'Add :NAT:PrimaryInterface:Enabled integer 1' \(plist)")
            pb.append("/usr/libexec/PlistBuddy -c 'Add :NAT:SharingDevices array' \(plist)")
            for dev in toDevices {
                pb.append("/usr/libexec/PlistBuddy -c 'Add :NAT:SharingDevices: string \(dev)' \(plist)")
            }
            _ = sharingList
        }

        // Toggle the launchd daemon. macOS has shipped the service under a couple
        // of labels; try both, ignoring failures for whichever isn't present.
        let daemon: String
        if enabled {
            daemon = """
            /bin/launchctl load -w /System/Library/LaunchDaemons/com.apple.InternetSharing.plist 2>/dev/null || true
            /bin/launchctl kickstart -k system/com.apple.InternetSharing 2>/dev/null || true
            /bin/launchctl kickstart -k system/com.apple.NetworkSharing 2>/dev/null || true
            """
        } else {
            daemon = """
            /bin/launchctl unload -w /System/Library/LaunchDaemons/com.apple.InternetSharing.plist 2>/dev/null || true
            /bin/launchctl bootout system/com.apple.InternetSharing 2>/dev/null || true
            /bin/launchctl bootout system/com.apple.NetworkSharing 2>/dev/null || true
            /usr/bin/killall natd bootpd 2>/dev/null || true
            """
        }

        let script = (pb.joined(separator: "\n") + "\n" + daemon)
        // Escape for embedding in an AppleScript "do shell script" string.
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let osa = "do shell script \"\(escaped)\" with administrator privileges"
        return await runOSAScript(osa)
    }

    // MARK: - Mac-as-router helpers

    /// Persistent file/anchor names for the custom router.
    private nonisolated static let routerPFAnchor = "com.remotestuff.router"
    private nonisolated static let routerPFAnchorPath = "/etc/pf.anchors/com.remotestuff.router"
    private nonisolated static let routerBootpdPlist = "/etc/bootpd.plist"
    private nonisolated static let routerDefaultsKey = "MacRouterConfig"
    private nonisolated static let routerFlagPath = "/tmp/com.remotestuff.router.active"
    /// DNS-forwarder (dnsmasq) file locations.
    private nonisolated static let dnsmasqConfPath = "/tmp/com.remotestuff.dnsmasq.conf"
    private nonisolated static let dnsmasqPlistPath = "/Library/LaunchDaemons/com.remotestuff.dnsmasq.plist"
    private nonisolated static let dnsmasqLabel = "com.remotestuff.dnsmasq"

    /// Router web-portal (status/config page on port 80) file locations.
    private nonisolated static let webLabel = "com.remotestuff.web"
    private nonisolated static let webPlistPath = "/Library/LaunchDaemons/com.remotestuff.web.plist"
    private nonisolated static let webScriptPath = "/tmp/com.remotestuff.web.py"
    private nonisolated static let webDataPath = "/tmp/com.remotestuff.web.json"
    private nonisolated static let webRequestPath = "/tmp/com.remotestuff.web.request.json"

    /// Locate a usable Python 3 interpreter for the web portal server. Prefers a
    /// real interpreter over the `/usr/bin/python3` CLT shim. Returns nil if none
    /// is found, in which case the portal is simply not started.
    nonisolated static func pythonPath() -> String? {
        for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                  "/usr/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Locate a usable dnsmasq binary (Homebrew on Apple silicon / Intel, or a
    /// system copy). Returns nil if none is installed — the router then hands out
    /// the upstream DNS directly instead of running a local forwarder.
    nonisolated static func dnsmasqPath() -> String? {
        for p in ["/opt/homebrew/sbin/dnsmasq", "/usr/local/sbin/dnsmasq",
                  "/opt/homebrew/bin/dnsmasq", "/usr/local/bin/dnsmasq"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Load the saved router config from UserDefaults (or defaults).
    nonisolated static func loadRouterConfig() -> MacRouterConfig {
        guard let data = UserDefaults.standard.data(forKey: routerDefaultsKey),
              let cfg = try? JSONDecoder().decode(MacRouterConfig.self, from: data) else {
            return MacRouterConfig()
        }
        return cfg
    }

    nonisolated static func saveRouterConfig(_ cfg: MacRouterConfig) {
        if let data = try? JSONEncoder().encode(cfg) {
            UserDefaults.standard.set(data, forKey: routerDefaultsKey)
        }
    }

    /// Whether the router appears to be up: the LAN device currently holds the
    /// configured router IP.
    nonisolated static func readRouterRunning(config: MacRouterConfig) async -> Bool {
        guard !config.lanDevice.isEmpty else { return false }
        let addr = await output("/usr/sbin/ipconfig", ["getifaddr", config.lanDevice])
        if addr.trimmingCharacters(in: .whitespacesAndNewlines) == config.routerIP { return true }
        // ipconfig only reports DHCP-assigned addresses; check ifconfig for a
        // manually-aliased address too.
        let cfg = await output("/sbin/ifconfig", [config.lanDevice])
        return cfg.contains("inet \(config.routerIP) ")
    }

    /// Build the plist for bootpd (the macOS DHCP server) as an XML string.
    private nonisolated static func bootpdPlistXML(_ c: MacRouterConfig, dns: String) -> String {
        let lease = max(60, c.leaseSeconds)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>bootp_enabled</key>
            <false/>
            <key>detect_other_dhcp_server</key>
            <integer>1</integer>
            <key>dhcp_enabled</key>
            <array>
                <string>\(c.lanDevice)</string>
            </array>
            <key>reply_threshold_seconds</key>
            <integer>0</integer>
            <key>Subnets</key>
            <array>
                <dict>
                    <key>allocate</key>
                    <true/>
                    <key>lease_max</key>
                    <integer>\(lease)</integer>
                    <key>lease_min</key>
                    <integer>\(lease)</integer>
                    <key>name</key>
                    <string>RemoteStuffLAN</string>
                    <key>net_address</key>
                    <string>\(c.networkAddress)</string>
                    <key>net_mask</key>
                    <string>\(c.subnetMask)</string>
                    <key>net_range</key>
                    <array>
                        <string>\(c.dhcpStart)</string>
                        <string>\(c.dhcpEnd)</string>
                    </array>
                    <key>dhcp_router</key>
                    <string>\(c.routerIP)</string>
                    <key>dhcp_domain_name_server</key>
                    <array>
                        <string>\(dns.isEmpty ? c.routerIP : dns)</string>
                    </array>
                </dict>
            </array>
        </dict>
        </plist>
        """
    }

    /// pf anchor ruleset: NAT the LAN subnet out the uplink and pass its traffic.
    /// Ends with a trailing newline — pf treats a final line without one as a
    /// syntax error.
    private nonisolated static func routerPFRules(_ c: MacRouterConfig) -> String {
        """
        nat on \(c.uplinkDevice) from \(c.networkAddress)/\(c.prefixLength) to any -> (\(c.uplinkDevice))
        pass in on \(c.lanDevice) from \(c.networkAddress)/\(c.prefixLength) to any keep state
        pass out on \(c.uplinkDevice) from \(c.networkAddress)/\(c.prefixLength) to any keep state

        """
    }

    /// Bring the custom router up or down under one admin prompt. Uses base64 to
    /// smuggle the multi-line config files past AppleScript quoting.
    nonisolated static func applyRouter(enabled: Bool, config c: MacRouterConfig) async -> Bool {
        var lines: [String] = ["set -e"]

        // Resolve the LAN device's network-service name so we can assign its IP
        // through `networksetup` (which registers the address with configd).
        // Assigning via raw `ifconfig` leaves macOS's scoped-routing source
        // selection unaware of the address, so connections that don't explicitly
        // bind a source fail with "Can't assign requested address". Falls back to
        // `ifconfig` only if the device has no matching service.
        let lanService = await serviceName(forDevice: c.lanDevice)

        if enabled {
            // 1. Assign the LAN IP (prefer networksetup; no router arg = no
            //    default route added).
            if let svc = lanService, !svc.isEmpty {
                lines.append("/usr/sbin/networksetup -setmanual \"\(svc)\" \(c.routerIP) \(c.subnetMask)")
            } else {
                lines.append("/sbin/ifconfig \(c.lanDevice) inet \(c.routerIP) netmask \(c.subnetMask) up")
            }
            // 1b. Belt-and-suspenders: strip any default route the LAN interface
            //     might carry (a stale DHCP lease can leave one, which breaks
            //     source selection for the rest of the machine).
            lines.append("/sbin/route -n delete -ifscope \(c.lanDevice) default 2>/dev/null || true")
            // 2. Enable IP forwarding.
            lines.append("/usr/sbin/sysctl -w net.inet.ip.forwarding=1")

            // 3. Write the pf anchor + a combined pf.conf that loads it.
            //    pf enforces a strict rule order (options → normalization →
            //    queueing → translation → filtering), so our nat-/rdr-anchors
            //    must be interleaved with Apple's *before* any filter anchors,
            //    and every `load anchor` goes at the very end. Appending our lines
            //    after the stock file breaks that order, so we build the ruleset
            //    ourselves in the correct sequence.
            let anchorB64 = Data(routerPFRules(c).utf8).base64EncodedString()
            lines.append("/bin/mkdir -p /etc/pf.anchors")
            lines.append("echo \(anchorB64) | /usr/bin/base64 -D > \(routerPFAnchorPath)")
            let combined = """
            scrub-anchor "com.apple/*"
            nat-anchor "com.apple/*"
            nat-anchor "\(routerPFAnchor)"
            rdr-anchor "com.apple/*"
            rdr-anchor "\(routerPFAnchor)"
            dummynet-anchor "com.apple/*"
            anchor "com.apple/*"
            anchor "\(routerPFAnchor)"
            load anchor "com.apple" from "/etc/pf.anchors/com.apple"
            load anchor "\(routerPFAnchor)" from "\(routerPFAnchorPath)"

            """
            // pf treats a final line without a trailing newline as a syntax
            // error, so guarantee one (the heredoc above may not preserve it).
            let confB64 = Data((combined.hasSuffix("\n") ? combined : combined + "\n").utf8).base64EncodedString()
            lines.append("echo \(confB64) | /usr/bin/base64 -D > /tmp/com.remotestuff.pf.conf")
            lines.append("/sbin/pfctl -E -f /tmp/com.remotestuff.pf.conf 2>/dev/null || /sbin/pfctl -e -f /tmp/com.remotestuff.pf.conf 2>/dev/null || true")

            // 4. Start a local DNS forwarder (dnsmasq) bound to the router IP, so
            //    clients that use the router as their DNS server (the standard
            //    setup, and what statically-configured devices expect) can resolve
            //    names. Falls back to handing out the upstream DNS directly if
            //    dnsmasq isn't installed.
            let upstreams = await upstreamDNSForRouter()
            let dnsmasq = dnsmasqPath()
            if let dnsmasq {
                let conf = dnsmasqConf(c, upstreams: upstreams)
                let confB64 = Data(conf.utf8).base64EncodedString()
                lines.append("echo \(confB64) | /usr/bin/base64 -D > \(dnsmasqConfPath)")
                let plist = dnsmasqPlistXML(binary: dnsmasq)
                let plistB64 = Data(plist.utf8).base64EncodedString()
                lines.append("echo \(plistB64) | /usr/bin/base64 -D > \(dnsmasqPlistPath)")
                lines.append("/bin/launchctl bootout system/\(dnsmasqLabel) 2>/dev/null || true")
                lines.append("/bin/launchctl bootstrap system \(dnsmasqPlistPath) 2>/dev/null || /bin/launchctl load -w \(dnsmasqPlistPath) 2>/dev/null || true")
                lines.append("/bin/launchctl kickstart -k system/\(dnsmasqLabel) 2>/dev/null || true")
            }

            // 5. Start the DHCP server if enabled. Hand out the router IP as the
            //    DNS server when the local forwarder is running; otherwise pass the
            //    upstream resolver through directly.
            if c.dhcpEnabled {
                let dnsForClients = dnsmasq != nil ? c.routerIP : (upstreams.first ?? c.routerIP)
                let bootpdB64 = Data(bootpdPlistXML(c, dns: dnsForClients).utf8).base64EncodedString()
                lines.append("echo \(bootpdB64) | /usr/bin/base64 -D > \(routerBootpdPlist)")
                lines.append("/bin/launchctl load -w /System/Library/LaunchDaemons/bootps.plist 2>/dev/null || true")
                lines.append("/bin/launchctl enable system/com.apple.bootpd 2>/dev/null || true")
                lines.append("/bin/launchctl kickstart -k system/com.apple.bootpd 2>/dev/null || /usr/libexec/bootpd 2>/dev/null || true")
            }

            // 6. Start the router web portal on port 80 (a small Python daemon),
            //    if enabled and a Python 3 interpreter is available. The data file
            //    is seeded now and refreshed by the app while the router runs.
            if c.webPortalEnabled, let python = pythonPath() {
                let dnsForClients = dnsmasqPath() != nil ? c.routerIP : (upstreams.first ?? c.routerIP)
                writeWebData(config: c, clients: [], dns: dnsForClients)
                lines.append("/bin/chmod 666 \(webDataPath) 2>/dev/null || true")
                lines.append("/bin/rm -f \(webRequestPath) 2>/dev/null || true")
                let scriptB64 = Data(webServerScript().utf8).base64EncodedString()
                lines.append("echo \(scriptB64) | /usr/bin/base64 -D > \(webScriptPath)")
                let webPlist = webPlistXML(python: python, routerIP: c.routerIP)
                let webPlistB64 = Data(webPlist.utf8).base64EncodedString()
                lines.append("echo \(webPlistB64) | /usr/bin/base64 -D > \(webPlistPath)")
                lines.append("/bin/launchctl bootout system/\(webLabel) 2>/dev/null || true")
                lines.append("/bin/launchctl bootstrap system \(webPlistPath) 2>/dev/null || /bin/launchctl load -w \(webPlistPath) 2>/dev/null || true")
                lines.append("/bin/launchctl kickstart -k system/\(webLabel) 2>/dev/null || true")
            }
            lines.append("/usr/bin/touch \(routerFlagPath)")
        } else {
            // Stop the web portal.
            lines.append("/bin/launchctl bootout system/\(webLabel) 2>/dev/null || true")
            lines.append("/bin/launchctl unload -w \(webPlistPath) 2>/dev/null || true")
            lines.append("/bin/rm -f \(webPlistPath) \(webScriptPath) \(webDataPath) \(webRequestPath) 2>/dev/null || true")
            // Stop the DNS forwarder.
            lines.append("/bin/launchctl bootout system/\(dnsmasqLabel) 2>/dev/null || true")
            lines.append("/bin/launchctl unload -w \(dnsmasqPlistPath) 2>/dev/null || true")
            lines.append("/bin/rm -f \(dnsmasqPlistPath) \(dnsmasqConfPath) 2>/dev/null || true")
            // Stop DHCP.
            lines.append("/bin/launchctl bootout system/com.apple.bootpd 2>/dev/null || true")
            lines.append("/bin/launchctl unload -w /System/Library/LaunchDaemons/bootps.plist 2>/dev/null || true")
            lines.append("/usr/bin/killall bootpd 2>/dev/null || true")
            // Flush + remove our pf anchor, reload the stock ruleset.
            lines.append("/sbin/pfctl -a \(routerPFAnchor) -F all 2>/dev/null || true")
            lines.append("/sbin/pfctl -f /etc/pf.conf 2>/dev/null || true")
            // Drop the LAN IP and disable forwarding.
            if let svc = lanService, !svc.isEmpty {
                lines.append("/usr/sbin/networksetup -setdhcp \"\(svc)\" 2>/dev/null || true")
            }
            // Always also strip any raw ifconfig alias — a router started by an
            // older build (or a half-applied config) leaves the address on the
            // interface even after the service reverts to DHCP, which would keep
            // it looking "running".
            if !c.lanDevice.isEmpty {
                lines.append("/sbin/ifconfig \(c.lanDevice) inet \(c.routerIP) -alias 2>/dev/null || true")
            }
            lines.append("/usr/sbin/sysctl -w net.inet.ip.forwarding=0 2>/dev/null || true")
            lines.append("/bin/rm -f \(routerFlagPath) 2>/dev/null || true")
        }

        let script = lines.joined(separator: "\n")
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let osa = "do shell script \"\(escaped)\" with administrator privileges"
        return await runOSAScript(osa)
    }

    /// Detect whether another device on the LAN already answers at `ip` (before
    /// we try to claim it). Sends a temporary ARP probe: pings the address a few
    /// times, then reads the ARP table for a resolved MAC that isn't one of our
    /// own interfaces. Returns a human-readable description of the conflicting
    /// device, or nil if the address appears free. Best-effort; never throws.
    nonisolated static func detectIPConflict(ip: String, device: String) async -> String? {
        // Collect our own MACs so we don't flag ourselves.
        let ifc = await output("/sbin/ifconfig", [])
        let ownMACs = Set(matches(in: ifc, pattern: #"ether\s+([0-9a-fA-F:]+)"#).map { $0.lowercased() })

        // Flush any stale entry, then provoke a fresh ARP resolution.
        _ = await output("/usr/sbin/arp", ["-d", ip])
        for _ in 0..<3 {
            _ = await output("/sbin/ping", ["-c", "1", "-t", "1", ip])
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        let arp = await output("/usr/sbin/arp", ["-n", ip])
        // "? (10.1.1.1) at 88:a2:9e:53:b9:7b on en10 ..." — grab the MAC.
        guard let mac = firstCapture(in: arp, pattern: #"at\s+([0-9a-fA-F:]+)\s"#),
              !mac.lowercased().contains("incomplete") else {
            return nil   // nothing answered — the address is free
        }
        let macLower = mac.lowercased()
        if ownMACs.contains(macLower) { return nil }   // that's us
        // Normalise short octets (macOS prints "8:a2:9e" not "08:a2:9e").
        let norm = macLower.split(separator: ":")
            .map { $0.count == 1 ? "0\($0)" : String($0) }
            .joined(separator: ":")
        return "A device with MAC address \(norm) is already using \(ip) on \(device)."
    }

    /// All capture-group-1 matches of `pattern` in `text`.
    private nonisolated static func matches(in text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap { m in
            guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    /// Map a BSD device name (e.g. "en10") to its network-service name (e.g.
    /// "USB 10/100/1000 LAN") from `-listnetworkserviceorder`. Nil if the device
    /// isn't backed by a configured service.
    nonisolated static func serviceName(forDevice bsd: String) async -> String? {
        let order = await output("/usr/sbin/networksetup", ["-listnetworkserviceorder"])
        var pending: String?
        for line in order.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let m = firstCapture(in: t, pattern: #"^\((?:\d+|\*)\)\s+(.*)$"#) {
                pending = m
            } else if t.contains("Device: \(bsd)"), let p = pending {
                return p
            }
        }
        return nil
    }

    /// The stock /etc/pf.conf contents (read at build time), used as the base for
    /// our combined ruleset so Apple's own anchors keep working.
    private nonisolated static func defaultPFConf() -> String {
        (try? String(contentsOfFile: "/etc/pf.conf", encoding: .utf8))
            ?? """
            scrub-anchor "com.apple/*"
            nat-anchor "com.apple/*"
            rdr-anchor "com.apple/*"
            dummynet-anchor "com.apple/*"
            anchor "com.apple/*"
            load anchor "com.apple" from "/etc/pf.anchors/com.apple"
            """
    }

    /// The upstream DNS servers the Mac is currently using (deduplicated, IPv4),
    /// which the router's DNS forwarder / DHCP hands downstream. Filters out any
    /// of our own LAN addresses so we never forward to ourselves. Falls back to
    /// public resolvers if none are found.
    private nonisolated static func upstreamDNSForRouter() async -> [String] {
        let scutil = await output("/usr/sbin/scutil", ["--dns"])
        var seen = Set<String>()
        var result: [String] = []
        for line in scutil.components(separatedBy: .newlines) {
            // Require a full dotted-quad IPv4 address. The old `[0-9.]+` pattern
            // captured the leading digits of an IPv6 nameserver (e.g. it turned
            // `2600:1700:...` into `2600`), producing a bogus `server=` line that
            // broke dnsmasq. Anchoring on four octets skips IPv6 lines cleanly.
            if let ip = firstCapture(in: line, pattern: #"nameserver\[\d+\]\s*:\s*(\d{1,3}(?:\.\d{1,3}){3})\b"#),
               !seen.contains(ip) {
                // Skip link-local / our own router IPs and loopback.
                if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") { continue }
                seen.insert(ip)
                result.append(ip)
            }
        }
        return result.isEmpty ? ["8.8.8.8", "1.1.1.1"] : result
    }

    /// dnsmasq config: bind to the router IP on port 53, act purely as a
    /// forwarding resolver (no DHCP — bootpd handles that), and forward to the
    /// Mac's upstream servers.
    private nonisolated static func dnsmasqConf(_ c: MacRouterConfig, upstreams: [String]) -> String {
        var lines = [
            "# Generated by Remote Stuff — Mac as Router DNS forwarder",
            "listen-address=\(c.routerIP)",
            "listen-address=127.0.0.1",
            "bind-interfaces",
            "port=53",
            "no-dhcp-interface=\(c.lanDevice)",  // DHCP is bootpd's job, not ours
            "no-resolv",                          // use only the servers below
            "no-poll",
            "cache-size=1000",
            "domain-needed",
            "bogus-priv",
        ]
        for up in upstreams { lines.append("server=\(up)") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// launchd plist that runs dnsmasq in the foreground (`-k`) with our config,
    /// kept alive by launchd, as a system daemon.
    private nonisolated static func dnsmasqPlistXML(binary: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(dnsmasqLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binary)</string>
                <string>-k</string>
                <string>--conf-file=\(dnsmasqConfPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardErrorPath</key>
            <string>/tmp/com.remotestuff.dnsmasq.log</string>
        </dict>
        </plist>
        """
    }

    // MARK: Router web portal (port 80)

    /// The self-contained Python 3 HTTP server for the router portal. Serves a
    /// live status/config page on port 80, reading the data file the app keeps
    /// refreshed and writing a request file when the config form is submitted
    /// (which the app then applies). Pure standard library — no dependencies.
    private nonisolated static func webServerScript() -> String {
        // NB: kept as a raw multi-line string; `%%` isn't used so no escaping of
        // Swift interpolation is needed — the paths are injected via os.environ
        // set in the launchd plist to avoid any string-substitution pitfalls.
        return #"""
        #!/usr/bin/env python3
        import json, os, html, urllib.parse
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        DATA = os.environ.get("RS_DATA", "/tmp/com.remotestuff.web.json")
        REQUEST = os.environ.get("RS_REQUEST", "/tmp/com.remotestuff.web.request.json")
        BIND = os.environ.get("RS_BIND", "0.0.0.0")
        PORT = int(os.environ.get("RS_PORT", "80"))

        def load():
            try:
                with open(DATA) as f:
                    return json.load(f)
            except Exception:
                return {}

        def esc(v):
            return html.escape(str(v if v is not None else ""))

        def page(d):
            cfg = d.get("config", {})
            clients = d.get("clients", [])
            rows = ""
            if clients:
                for c in clients:
                    dot = "#33c15a" if c.get("active") else "#9b9b9b"
                    rows += (
                        "<tr>"
                        f"<td><span class='dot' style='background:{dot}'></span>{esc(c.get('name') or c.get('ip'))}</td>"
                        f"<td class='mono'>{esc(c.get('ip'))}</td>"
                        f"<td class='mono'>{esc(c.get('mac'))}</td>"
                        f"<td>{'Online' if c.get('active') else 'Idle'}</td>"
                        "</tr>"
                    )
            else:
                rows = "<tr><td colspan='4' class='muted'>No devices seen yet.</td></tr>"

            def field(label, name, value, typ="text"):
                return (
                    f"<label>{esc(label)}"
                    f"<input name='{name}' type='{typ}' value='{esc(value)}'></label>"
                )

            dhcp_checked = "checked" if cfg.get("dhcpEnabled") else ""
            saved = d.get("savedNote", "")
            note = f"<div class='note'>{esc(saved)}</div>" if saved else ""

            return f"""<!doctype html>
        <html><head><meta charset='utf-8'>
        <meta name='viewport' content='width=device-width, initial-scale=1'>
        <title>Router — {esc(cfg.get('routerIP'))}</title>
        <style>
          :root {{ color-scheme: light dark; }}
          body {{ font: 15px -apple-system, system-ui, sans-serif; margin: 0; background:#f5f5f7; color:#1d1d1f; }}
          @media (prefers-color-scheme: dark) {{ body {{ background:#1c1c1e; color:#f5f5f7; }} .card{{background:#2c2c2e!important;}} input{{background:#1c1c1e;color:#f5f5f7;border-color:#444!important;}} th{{color:#aaa!important;}} }}
          .wrap {{ max-width: 760px; margin: 0 auto; padding: 24px 16px 48px; }}
          h1 {{ font-size: 22px; margin: 8px 0 2px; }}
          .sub {{ color:#86868b; margin:0 0 20px; }}
          .card {{ background:#fff; border-radius:12px; padding:18px 20px; margin-bottom:18px; box-shadow:0 1px 3px rgba(0,0,0,.08); }}
          .grid {{ display:grid; grid-template-columns:1fr 1fr; gap:6px 24px; }}
          .grid div {{ padding:6px 0; border-bottom:1px solid rgba(128,128,128,.15); }}
          .k {{ color:#86868b; font-size:13px; }}
          .mono {{ font-family: ui-monospace, Menlo, monospace; }}
          table {{ width:100%; border-collapse:collapse; }}
          th, td {{ text-align:left; padding:8px 6px; border-bottom:1px solid rgba(128,128,128,.15); font-size:14px; }}
          th {{ color:#86868b; font-weight:600; font-size:12px; text-transform:uppercase; letter-spacing:.4px; }}
          .dot {{ display:inline-block; width:9px; height:9px; border-radius:50%; margin-right:8px; vertical-align:middle; }}
          .muted {{ color:#86868b; text-align:center; }}
          label {{ display:block; font-size:13px; color:#86868b; margin-bottom:12px; }}
          input {{ display:block; width:100%; box-sizing:border-box; margin-top:4px; padding:8px 10px; font-size:15px; border:1px solid #d2d2d7; border-radius:8px; }}
          .row {{ display:grid; grid-template-columns:1fr 1fr; gap:0 20px; }}
          .chk {{ display:flex; align-items:center; gap:8px; color:inherit; }}
          .chk input {{ width:auto; margin:0; }}
          button {{ background:#0071e3; color:#fff; border:0; border-radius:8px; padding:10px 20px; font-size:15px; font-weight:500; cursor:pointer; }}
          .note {{ background:#e8f5e9; color:#1b5e20; padding:10px 14px; border-radius:8px; margin-bottom:14px; font-size:14px; }}
          @media (prefers-color-scheme: dark) {{ .note {{ background:#14361a; color:#a5d6a7; }} }}
          .hint {{ color:#86868b; font-size:12px; margin-top:10px; }}
        </style></head>
        <body><div class='wrap'>
          <h1>Mac Router</h1>
          <p class='sub'>Hosted by Remote Stuff on {esc(cfg.get('routerIP'))}</p>
          {note}
          <div class='card'>
            <div class='grid'>
              <div><div class='k'>Router IP</div><span class='mono'>{esc(cfg.get('routerIP'))}</span></div>
              <div><div class='k'>Subnet mask</div><span class='mono'>{esc(cfg.get('subnetMask'))}</span></div>
              <div><div class='k'>Uplink (internet)</div><span class='mono'>{esc(cfg.get('uplinkDevice'))}</span></div>
              <div><div class='k'>LAN interface</div><span class='mono'>{esc(cfg.get('lanDevice'))}</span></div>
              <div><div class='k'>DHCP</div>{'On' if cfg.get('dhcpEnabled') else 'Off'} ({esc(cfg.get('dhcpStart'))} – {esc(cfg.get('dhcpEnd'))})</div>
              <div><div class='k'>Lease</div>{esc(cfg.get('leaseHours'))} h</div>
              <div><div class='k'>DNS</div><span class='mono'>{esc(cfg.get('dns'))}</span></div>
              <div><div class='k'>Connected devices</div>{len(clients)}</div>
            </div>
          </div>

          <div class='card'>
            <h2 style='font-size:16px;margin:0 0 12px'>Connected Devices</h2>
            <table><thead><tr><th>Name</th><th>IP</th><th>MAC</th><th>Status</th></tr></thead>
            <tbody>{rows}</tbody></table>
          </div>

          <div class='card'>
            <h2 style='font-size:16px;margin:0 0 14px'>Configure</h2>
            <form method='POST' action='/apply'>
              <div class='row'>
                {field('Router IP', 'routerIP', cfg.get('routerIP'))}
                {field('Subnet mask', 'subnetMask', cfg.get('subnetMask'))}
              </div>
              <label class='chk'><input type='checkbox' name='dhcpEnabled' value='1' {dhcp_checked}> Run DHCP server</label>
              <div class='row'>
                {field('DHCP start', 'dhcpStart', cfg.get('dhcpStart'))}
                {field('DHCP end', 'dhcpEnd', cfg.get('dhcpEnd'))}
              </div>
              {field('Lease (hours)', 'leaseHours', cfg.get('leaseHours'), 'number')}
              <button type='submit'>Apply Changes</button>
              <div class='hint'>Applying restarts the router. The Mac hosting it will prompt for an administrator password before the change takes effect.</div>
            </form>
          </div>
          <p class='sub' style='text-align:center'>This page refreshes automatically.</p>
        </div>
        <script>
          setTimeout(function(){{ if(!document.querySelector('input:focus')) location.reload(); }}, 15000);
        </script>
        </body></html>"""

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def _send(self, code, body, ctype="text/html; charset=utf-8"):
                data = body.encode("utf-8")
                self.send_response(code)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(data)
            def do_GET(self):
                d = load()
                if self.path.startswith("/data.json"):
                    self._send(200, json.dumps(d), "application/json")
                else:
                    self._send(200, page(d))
            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                raw = self.rfile.read(length).decode("utf-8") if length else ""
                form = urllib.parse.parse_qs(raw)
                def g(k, default=""):
                    v = form.get(k)
                    return v[0] if v else default
                req = {
                    "routerIP": g("routerIP"),
                    "subnetMask": g("subnetMask"),
                    "dhcpEnabled": ("dhcpEnabled" in form),
                    "dhcpStart": g("dhcpStart"),
                    "dhcpEnd": g("dhcpEnd"),
                    "leaseHours": g("leaseHours", "24"),
                }
                try:
                    with open(REQUEST, "w") as f:
                        json.dump(req, f)
                    os.chmod(REQUEST, 0o666)
                except Exception:
                    pass
                self.send_response(303)
                self.send_header("Location", "/")
                self.end_headers()

        if __name__ == "__main__":
            httpd = ThreadingHTTPServer((BIND, PORT), Handler)
            httpd.serve_forever()
        """#
    }

    /// launchd plist that runs the Python web portal as a system daemon on
    /// port 80, kept alive by launchd. Paths are passed through the environment
    /// so the script itself needs no substitution. Binds to all interfaces
    /// (0.0.0.0) rather than the router IP so it comes up even before the LAN
    /// address is fully live (avoiding a bind race) and recovers automatically.
    private nonisolated static func webPlistXML(python: String, routerIP: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(webLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(python)</string>
                <string>\(webScriptPath)</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict>
                <key>RS_DATA</key><string>\(webDataPath)</string>
                <key>RS_REQUEST</key><string>\(webRequestPath)</string>
                <key>RS_BIND</key><string>0.0.0.0</string>
                <key>RS_PORT</key><string>80</string>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ThrottleInterval</key>
            <integer>5</integer>
            <key>StandardErrorPath</key>
            <string>/tmp/com.remotestuff.web.log</string>
        </dict>
        </plist>
        """
    }

    /// Serialize the live router state (config + clients) to the data file the
    /// web portal reads. Best-effort; safe to call frequently.
    nonisolated static func writeWebData(config c: MacRouterConfig,
                                         clients: [RouterClient],
                                         dns: String,
                                         savedNote: String? = nil) {
        let clientObjs: [[String: Any]] = clients.map {
            ["ip": $0.ip, "mac": $0.mac, "name": $0.displayName, "active": $0.isActive]
        }
        let cfg: [String: Any] = [
            "routerIP": c.routerIP,
            "subnetMask": c.subnetMask,
            "uplinkDevice": c.uplinkDevice,
            "lanDevice": c.lanDevice,
            "dhcpEnabled": c.dhcpEnabled,
            "dhcpStart": c.dhcpStart,
            "dhcpEnd": c.dhcpEnd,
            "leaseHours": max(1, c.leaseSeconds / 3600),
            "dns": dns,
        ]
        var payload: [String: Any] = ["config": cfg, "clients": clientObjs]
        if let savedNote { payload["savedNote"] = savedNote }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: webDataPath))
    }

    /// Read and clear a pending config change submitted through the web portal.
    /// Returns a config derived from the current one with the requested fields
    /// applied, or nil if there's no valid pending request.
    nonisolated static func consumeWebConfigRequest(base: MacRouterConfig) -> MacRouterConfig? {
        let url = URL(fileURLWithPath: webRequestPath)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        var cfg = base
        if let s = obj["routerIP"] as? String, isValidIPv4Static(s) { cfg.routerIP = s }
        if let s = obj["subnetMask"] as? String, isValidIPv4Static(s) { cfg.subnetMask = s }
        if let b = obj["dhcpEnabled"] as? Bool { cfg.dhcpEnabled = b }
        if let s = obj["dhcpStart"] as? String, isValidIPv4Static(s) { cfg.dhcpStart = s }
        if let s = obj["dhcpEnd"] as? String, isValidIPv4Static(s) { cfg.dhcpEnd = s }
        if let s = obj["leaseHours"] as? String, let h = Int(s), h > 0 {
            cfg.leaseSeconds = h * 3600
        }
        return cfg
    }

    /// A context-free IPv4 validator usable from nonisolated static helpers.
    private nonisolated static func isValidIPv4Static(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            guard let n = Int(p), (0...255).contains(n) else { return false }
            return true
        }
    }

    /// Read the devices on the router LAN: parse the bootpd lease file and merge
    /// with the live ARP table (ARP membership marks a client "active").
    nonisolated static func readRouterClients(config c: MacRouterConfig) async -> [RouterClient] {
        var byMac: [String: RouterClient] = [:]

        // 1. DHCP leases from /var/db/dhcpd_leases.
        let leases = (try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8)) ?? ""
        var name: String?; var ip: String?; var mac: String?
        for raw in leases.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "{" { name = nil; ip = nil; mac = nil }
            else if line.hasPrefix("name=") { name = String(line.dropFirst(5)) }
            else if line.hasPrefix("ip_address=") { ip = String(line.dropFirst(11)) }
            else if line.hasPrefix("hw_address=") {
                // Format "1,aa:bb:cc:dd:ee:ff" — drop the hw-type prefix.
                let v = String(line.dropFirst(11))
                mac = v.contains(",") ? String(v.split(separator: ",").last ?? "") : v
            } else if line == "}" {
                if let ip, ipInSubnet(ip, config: c) {
                    let key = (mac ?? ip).lowercased()
                    byMac[key] = RouterClient(ip: ip, mac: mac ?? "",
                                              hostName: name, isActive: false)
                }
            }
        }

        // 2. ARP table — marks who's actually reachable, and catches static clients.
        let arp = await output("/usr/sbin/arp", ["-an"])
        for raw in arp.components(separatedBy: .newlines) {
            // "? (10.1.1.100) at aa:bb:cc:dd:ee:ff on en7 ifscope [ethernet]"
            guard let aip = firstCapture(in: raw, pattern: #"\(([0-9.]+)\)"#),
                  ipInSubnet(aip, config: c) else { continue }
            let amac = firstCapture(in: raw, pattern: #"at\s+([0-9a-fA-F:]+)\s+on"#) ?? ""
            if aip == c.routerIP { continue }   // skip ourselves
            let key = (amac.isEmpty ? aip : amac).lowercased()
            if var existing = byMac[key] {
                existing.isActive = true
                if existing.mac.isEmpty { existing.mac = amac }
                byMac[key] = existing
            } else {
                byMac[key] = RouterClient(ip: aip, mac: amac, hostName: nil, isActive: true)
            }
        }

        return byMac.values.sorted { $0.ip.compare($1.ip, options: .numeric) == .orderedAscending }
    }

    /// Whether an IPv4 address falls within the router's configured subnet.
    private nonisolated static func ipInSubnet(_ ip: String, config c: MacRouterConfig) -> Bool {
        let a = ip.split(separator: ".").compactMap { UInt32($0) }
        let net = c.networkAddress.split(separator: ".").compactMap { UInt32($0) }
        let mk = c.subnetMask.split(separator: ".").compactMap { UInt32($0) }
        guard a.count == 4, net.count == 4, mk.count == 4 else { return false }
        for i in 0..<4 where (a[i] & mk[i]) != net[i] { return false }
        return true
    }

    // MARK: - Parsers


    /// Enumerate active interfaces, joining `ifconfig` addresses with friendly
    /// names / media types from `networksetup -listallhardwareports`.
    nonisolated static func readInterfaces() async -> [MacInterface] {        let hardware = await output("/usr/sbin/networksetup", ["-listallhardwareports"])
        var friendly: [String: String] = [:]   // bsd -> port name
        do {
            var currentName: String?
            for line in hardware.components(separatedBy: .newlines) {
                if line.hasPrefix("Hardware Port:") {
                    currentName = line.replacingOccurrences(of: "Hardware Port:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("Device:") {
                    let dev = line.replacingOccurrences(of: "Device:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if let n = currentName { friendly[dev] = n }
                }
            }
        }

        let ifconfig = await output("/sbin/ifconfig", [])
        var result: [MacInterface] = []
        var current: MacInterface?

        func flush() {
            if let c = current,
               // Surface interfaces that either have an address, or are a real
               // hardware port (Wi-Fi / Ethernet / USB LAN) — the latter so an
               // unconfigured LAN adapter still appears (e.g. to pick as the
               // router's LAN interface before it has an IP).
               (!c.ipv4.isEmpty || !c.ipv6.isEmpty || friendly[c.bsdName] != nil),
               !c.bsdName.hasPrefix("lo"), !c.bsdName.hasPrefix("gif"),
               !c.bsdName.hasPrefix("stf") {
                result.append(c)
            }
        }

        for rawLine in ifconfig.components(separatedBy: .newlines) {
            if !rawLine.hasPrefix("\t") && !rawLine.hasPrefix(" ") && rawLine.contains(":") {
                // New interface header, e.g. "en0: flags=8863<UP,BROADCAST,...>"
                flush()
                let name = String(rawLine.prefix(while: { $0 != ":" }))
                let isUp = rawLine.contains("UP") && rawLine.contains("RUNNING")
                current = MacInterface(bsdName: name,
                                       friendlyName: friendly[name] ?? name,
                                       isUp: isUp, ipv4: [], ipv6: [],
                                       macAddress: nil, mediaType: nil)
            } else {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("inet ") {
                    let parts = line.components(separatedBy: .whitespaces)
                    if parts.count >= 2 { current?.ipv4.append(parts[1]) }
                } else if line.hasPrefix("inet6 ") {
                    let parts = line.components(separatedBy: .whitespaces)
                    if parts.count >= 2 {
                        let addr = parts[1].components(separatedBy: "%").first ?? parts[1]
                        if !addr.hasPrefix("fe80") { current?.ipv6.append(addr) }
                    }
                } else if line.hasPrefix("ether ") {
                    let parts = line.components(separatedBy: .whitespaces)
                    if parts.count >= 2 { current?.macAddress = parts[1] }
                } else if line.hasPrefix("status:") {
                    // Reflect real link state: "status: active" means a cable /
                    // link is present. Overrides the flags-based guess so an
                    // unplugged adapter reads as Down.
                    current?.isUp = line.contains("active")
                }
            }
        }
        flush()
        return result
    }

    /// The default IPv4 gateway (`route -n get default`).
    nonisolated static func readDefaultGateway() async -> String? {
        let out = await output("/sbin/route", ["-n", "get", "default"])
        for line in out.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") {
                return t.replacingOccurrences(of: "gateway:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// The resolver's DNS servers (`scutil --dns`), de-duplicated in order.
    nonisolated static func readDNSServers() async -> [String] {
        let out = await output("/usr/sbin/scutil", ["--dns"])
        var seen = Set<String>()
        var servers: [String] = []
        for line in out.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            // Lines look like: "nameserver[0] : 1.1.1.1"
            if t.hasPrefix("nameserver[") {
                if let ip = t.components(separatedBy: ":").last?
                    .trimmingCharacters(in: .whitespaces), !ip.isEmpty, !seen.contains(ip) {
                    seen.insert(ip)
                    servers.append(ip)
                }
            }
        }
        return servers
    }

    /// Current Wi-Fi association details via the `airport` private tool, falling
    /// back to `wdutil` on newer macOS where `airport -I` was removed.
    nonisolated static func readWiFi() async -> WiFiInfo? {
        let airportPath = "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
        if FileManager.default.isExecutableFile(atPath: airportPath) {
            let out = await output(airportPath, ["-I"])
            if !out.trimmingCharacters(in: .whitespaces).isEmpty, out.contains("SSID") {
                var info = WiFiInfo()
                for line in out.components(separatedBy: .newlines) {
                    let parts = line.components(separatedBy: ":")
                    guard parts.count >= 2 else { continue }
                    let key = parts[0].trimmingCharacters(in: .whitespaces)
                    let val = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                    switch key {
                    case "SSID":         info.ssid = val
                    case "BSSID":        info.bssid = val
                    case "agrCtlRSSI":   info.rssi = Int(val)
                    case "agrCtlNoise":  info.noise = Int(val)
                    case "lastTxRate":   info.txRate = Double(val)
                    case "channel":      info.channel = val
                    default: break
                    }
                }
                if info.ssid != nil { return info }
            }
        }
        return nil
    }

    /// Look up the Mac's public IP via a plain-text endpoint. Returns nil offline.
    nonisolated static func fetchPublicIP() async -> String? {
        guard let url = URL(string: "https://api.ipify.org") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let ip = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !ip.isEmpty else { return nil }
            return ip
        } catch {
            return nil
        }
    }
}
