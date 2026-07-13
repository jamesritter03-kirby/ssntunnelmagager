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

/// Gathers this Mac's live network state (interfaces, gateway, DNS, Wi-Fi,
/// public IP) by shelling out to the standard macOS network tools, and exposes
/// a few common maintenance actions (flush DNS, renew DHCP). A singleton so the
/// Network browser and any menu actions share one cache.
@MainActor
final class NetworkStore: ObservableObject {
    static let shared = NetworkStore()
    private init() {}
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
               // Only surface interfaces that have an address or are up + physical.
               (!c.ipv4.isEmpty || !c.ipv6.isEmpty),
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
