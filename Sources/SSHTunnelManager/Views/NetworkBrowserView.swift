import SwiftUI

/// Drives the Network management sheet. A singleton so the menu, the sidebar and
/// any other entry point can present it while the main window hosts it.
/// Mirrors `ZeroTierBrowserModel`.
final class NetworkBrowserModel: ObservableObject {
    static let shared = NetworkBrowserModel()
    private init() {}

    @Published var isPresented = false
    func present() { isPresented = true }
}

/// The left-list selection in the Network browser.
private enum NetworkSelection: Hashable {
    case thisMac
    case router(UUID)
}

/// A window that manages this Mac's networking and any saved MikroTik routers.
/// The left list shows "This Mac" plus each saved router; the detail pane shows
/// live status and actions for the current selection.
struct NetworkBrowserView: View {
    @ObservedObject var net = NetworkStore.shared
    @ObservedObject var mikro = MikroTikStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selection: NetworkSelection = .thisMac
    /// Router being added/edited in the form sheet, or nil when hidden.
    @State private var editingRouter: MikroTikRouter?
    @State private var editingPassword = ""
    @State private var isNewRouter = false
    @State private var routerPendingDelete: MikroTikRouter?

    var body: some View {
        NavigationSplitView {
            sidebar
                .frame(minWidth: 220)
        } detail: {
            detail
        }
        .frame(minWidth: 820, idealWidth: 960, maxWidth: .infinity,
               minHeight: 560, idealHeight: 680, maxHeight: .infinity)
        .background(NetworkResizableSheet())
        .task { await net.refresh() }
        .task { await mikro.discover() }
        .sheet(item: $editingRouter) { _ in routerForm }
        .confirmationDialog(
            routerPendingDelete.map { "Remove “\($0.displayName)”?" } ?? "Remove router?",
            isPresented: Binding(get: { routerPendingDelete != nil },
                                 set: { if !$0 { routerPendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let r = routerPendingDelete {
                    mikro.removeRouter(r.id)
                    if selection == .router(r.id) { selection = .thisMac }
                }
                routerPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { routerPendingDelete = nil }
        } message: {
            Text("This removes the saved router and its stored password from this Mac.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("This Mac") {
                Label(net.hostName, systemImage: "laptopcomputer")
                    .tag(NetworkSelection.thisMac)
            }
            Section("MikroTik Routers") {
                ForEach(mikro.routers) { router in
                    routerRow(router)
                        .tag(NetworkSelection.router(router.id))
                        .contextMenu {
                            Button("Refresh") { Task { await mikro.refresh(router) } }
                            Button("Edit…") { beginEdit(router) }
                            Divider()
                            Button("Remove…", role: .destructive) { routerPendingDelete = router }
                        }
                }
                if mikro.routers.isEmpty {
                    Text("No routers yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !mikro.discovered.isEmpty || mikro.isDiscovering {
                Section("Discovered on Network") {
                    if mikro.isDiscovering && mikro.discovered.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Scanning…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(mikro.discovered) { device in
                        discoveredRow(device)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    beginAdd()
                } label: {
                    Label("Add Router", systemImage: "plus")
                }
                Spacer()
                if mikro.isDiscovering {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await net.refresh() }
                    Task { await mikro.discover() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh and scan for routers")
            }
            .padding(8)
            .background(.bar)
        }
    }

    /// A discovered (not-yet-saved) MikroTik device with a quick add button.
    private func discoveredRow(_ device: DiscoveredRouter) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "badge.plus.radiowaves.right")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName)
                Text([device.ipv4, device.board].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                beginAdd(from: device)
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Add this router")
        }
        .contextMenu {
            Button("Add Router…") { beginAdd(from: device) }
        }
    }

    private func routerRow(_ router: MikroTikRouter) -> some View {
        let loading = mikro.loading.contains(router.id)
        let hasError = mikro.errors[router.id] != nil
        return HStack(spacing: 8) {
            Image(systemName: "wifi.router")
                .foregroundStyle(hasError ? .orange : .primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(router.displayName)
                Text(router.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if loading { ProgressView().controlSize(.small) }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .thisMac:
            MacNetworkDetail(net: net)
        case .router(let id):
            if let router = mikro.routers.first(where: { $0.id == id }) {
                RouterDetail(router: router, mikro: mikro,
                             onEdit: { beginEdit(router) },
                             onDelete: { routerPendingDelete = router })
            } else {
                ContentUnavailablePlaceholder(text: "Select a router")
            }
        }
    }

    // MARK: - Router form

    private var routerForm: some View {
        RouterForm(
            router: Binding(
                get: { editingRouter ?? MikroTikRouter() },
                set: { editingRouter = $0 }),
            password: $editingPassword,
            isNew: isNewRouter,
            onSave: {
                guard let r = editingRouter else { return }
                if isNewRouter {
                    _ = mikro.addRouter(r, password: editingPassword)
                    selection = .router(r.id)
                } else {
                    mikro.updateRouter(r, password: editingPassword.isEmpty ? nil : editingPassword)
                }
                editingRouter = nil
                editingPassword = ""
            },
            onCancel: {
                editingRouter = nil
                editingPassword = ""
            })
    }

    private func beginAdd() {
        editingRouter = MikroTikRouter()
        editingPassword = ""
        isNewRouter = true
    }

    /// Start adding a router, pre-filled from an auto-discovered device.
    private func beginAdd(from device: DiscoveredRouter) {
        var router = MikroTikRouter()
        router.name = device.identity ?? ""
        router.host = device.suggestedHost
        editingRouter = router
        editingPassword = ""
        isNewRouter = true
    }

    private func beginEdit(_ router: MikroTikRouter) {
        editingRouter = router
        editingPassword = ""
        isNewRouter = false
    }
}

// MARK: - This Mac detail

private struct MacNetworkDetail: View {
    @ObservedObject var net: NetworkStore

    /// Draft selections for the Internet Sharing form.
    @State private var shareSource = ""
    @State private var shareTo: Set<String> = []
    @State private var applyingShare = false

    /// Whether the advanced "Mac as router" panel is expanded.
    @State private var showRouter = false

    /// Which inline editor sheet is open, if any.
    @State private var editingDNS = false
    @State private var editingGateway = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let wifi = net.wifi, wifi.ssid != nil {
                    section("Wi-Fi") {
                        wifiRows(wifi)
                    }
                }

                section("Overview") {
                    HStack {
                        Text("Public IP").foregroundStyle(.secondary)
                        Spacer()
                        if let ip = net.publicIP { CopyableText(text: ip, font: .callout) }
                        else { Text("—") }
                    }
                    editableRow("Default gateway", net.defaultGateway ?? "—",
                                copyable: net.defaultGateway) { editingGateway = true }
                    editableRow("DNS servers",
                                net.dnsServers.isEmpty ? "—" : net.dnsServers.joined(separator: ", "),
                                copyable: net.dnsServers.isEmpty ? nil : net.dnsServers.joined(separator: ", ")) {
                        editingDNS = true
                    }
                    if let svc = net.primaryService {
                        Text("Edits apply to “\(svc)”.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                section("Interfaces") {
                    ForEach(net.interfaces) { iface in
                        interfaceRow(iface)
                        if iface.id != net.interfaces.last?.id { Divider() }
                    }
                }

                sharingSection

                routerSection

                actions
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: syncShareDraft)
        .onChange(of: net.sharing) { _ in syncShareDraft() }
        .sheet(isPresented: $editingDNS) {
            DNSEditor(current: net.dnsServers,
                      service: net.primaryService,
                      gateway: net.defaultGateway,
                      sharingOn: net.sharing.isRunning || net.sharing.isEnabled) { servers in
                Task { await net.setDNSServers(servers) }
            }
        }
        .sheet(isPresented: $editingGateway) {
            GatewayEditor(current: net.defaultGateway ?? "",
                          service: net.primaryService,
                          dnsServers: net.dnsServers,
                          sharingOn: net.sharing.isRunning || net.sharing.isEnabled) { gw, ip, mask in
                Task { await net.setGateway(gw, persistOn: net.primaryService, ip: ip, mask: mask) }
            }
        }
    }

    private var header: some View {
        HStack {
            Label(net.hostName, systemImage: "laptopcomputer")
                .font(.title2.bold())
            Spacer()
            if net.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await net.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
        }
    }

    @ViewBuilder
    private func wifiRows(_ wifi: WiFiInfo) -> some View {
        infoRow("Network", wifi.ssid ?? "—")
        if let pct = wifi.signalPercent {
            HStack {
                Text("Signal").foregroundStyle(.secondary)
                Spacer()
                ProgressView(value: Double(pct), total: 100)
                    .frame(width: 120)
                Text("\(pct)%").monospacedDigit()
            }
        }
        if let rssi = wifi.rssi { infoRow("RSSI", "\(rssi) dBm") }
        if let ch = wifi.channel { infoRow("Channel", ch) }
        if let tx = wifi.txRate { infoRow("Tx rate", "\(Int(tx)) Mbps") }
    }

    private func interfaceRow(_ iface: MacInterface) -> some View {
        HStack(alignment: .top) {
            Image(systemName: icon(for: iface))
                .foregroundStyle(iface.isUp ? Color.green : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(iface.friendlyName).fontWeight(.medium)
                    Text(iface.bsdName).font(.caption).foregroundStyle(.secondary)
                }
                if let ip = iface.primaryIPv4 {
                    CopyableText(text: ip, font: .callout)
                }
                if let mac = iface.macAddress {
                    CopyableText(text: mac, font: .caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(iface.isUp ? "Up" : "Down")
                .font(.caption)
                .foregroundStyle(iface.isUp ? .green : .secondary)
        }
    }

    private func icon(for iface: MacInterface) -> String {
        let name = (iface.mediaType ?? iface.friendlyName).lowercased()
        if name.contains("wi") { return "wifi" }
        if name.contains("ether") { return "cable.connector" }
        if iface.bsdName.hasPrefix("utun") || iface.bsdName.hasPrefix("ppp") { return "lock.shield" }
        return "network"
    }

    // MARK: Internet Sharing

    private var shareableInterfaces: [MacInterface] { net.interfaces }

    private var sharingSection: some View {
        section("Internet Sharing") {
            HStack {
                Circle()
                    .fill(net.sharing.isRunning ? Color.green : (net.sharing.isEnabled ? Color.orange : Color.secondary))
                    .frame(width: 8, height: 8)
                Text(sharingStatusText).fontWeight(.medium)
                Spacer()
                if net.sharing.isEnabled || net.sharing.isRunning {
                    Button(role: .destructive) {
                        applyingShare = true
                        Task { await net.disableSharing(); applyingShare = false }
                    } label: { Text("Turn Off") }
                    .disabled(applyingShare)
                }
            }

            Divider()

            // Source (the connection to share).
            HStack(alignment: .firstTextBaseline) {
                Text("Share from").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                Picker("", selection: $shareSource) {
                    Text("Select…").tag("")
                    ForEach(shareableInterfaces) { iface in
                        Text(interfaceLabel(iface)).tag(iface.bsdName)
                    }
                }
                .labelsHidden()
            }

            // Targets (the interfaces to share to).
            HStack(alignment: .top) {
                Text("To").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shareableInterfaces.filter { $0.bsdName != shareSource }) { iface in
                        Toggle(isOn: Binding(
                            get: { shareTo.contains(iface.bsdName) },
                            set: { on in
                                if on { shareTo.insert(iface.bsdName) } else { shareTo.remove(iface.bsdName) }
                            })) {
                            Text(interfaceLabel(iface))
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    applyingShare = true
                    let src = shareSource
                    let to = Array(shareTo)
                    Task { await net.enableSharing(source: src, toDevices: to); applyingShare = false }
                } label: {
                    if applyingShare { ProgressView().controlSize(.small) }
                    else { Text(net.sharing.isEnabled ? "Update Sharing" : "Turn On") }
                }
                .disabled(applyingShare || shareSource.isEmpty || shareTo.isEmpty)
            }

            Text("Shares one connection’s internet access out over the selected interfaces (NAT), like System Settings ▸ Sharing ▸ Internet Sharing. Changes need an administrator password.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sharingStatusText: String {
        if net.sharing.isRunning || net.sharing.isEnabled {
            let src = net.sharing.sourceDevice.isEmpty ? "?" : friendlyName(net.sharing.sourceDevice)
            let to = net.sharing.toDevices.map(friendlyName).joined(separator: ", ")
            return net.sharing.isRunning
                ? "On — sharing \(src) → \(to.isEmpty ? "?" : to)"
                : "Configured (not running) — \(src) → \(to)"
        }
        return "Off"
    }

    private func interfaceLabel(_ iface: MacInterface) -> String {
        let ip = iface.primaryIPv4.map { " · \($0)" } ?? ""
        return "\(iface.friendlyName) (\(iface.bsdName))\(ip)"
    }

    private func friendlyName(_ bsd: String) -> String {
        net.interfaces.first { $0.bsdName == bsd }?.friendlyName ?? bsd
    }

    // MARK: Mac as Router

    /// Binding into the store's persisted router config.
    private var cfg: Binding<MacRouterConfig> { $net.routerConfig }

    private var routerSection: some View {
        section("Mac as Router (Advanced)") {
            HStack {
                Circle()
                    .fill(net.routerRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(net.routerRunning
                     ? "Running — \(net.routerConfig.routerIP) on \(friendlyName(net.routerConfig.lanDevice))"
                     : "Off")
                    .fontWeight(.medium)
                Spacer()
                Button {
                    withAnimation { showRouter.toggle() }
                } label: {
                    Image(systemName: showRouter ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .help(showRouter ? "Hide router settings" : "Configure router")
            }

            if net.routerRunning {
                Divider()
                connectedDevices
            }

            if showRouter {
                Divider()
                routerForm
            }

            Text("Turns this Mac into a full router: assigns a fixed IP to a LAN interface, hands out addresses over its own DHCP server, and NATs traffic out an uplink. Great for sharing Wi‑Fi to a USB Ethernet adapter on a custom subnet. Needs an administrator password.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var routerForm: some View {
        // Uplink (internet source).
        HStack(alignment: .firstTextBaseline) {
            Text("Uplink").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Picker("", selection: cfg.uplinkDevice) {
                Text("Select…").tag("")
                ForEach(shareableInterfaces) { iface in
                    Text(interfaceLabel(iface)).tag(iface.bsdName)
                }
            }
            .labelsHidden()
        }
        // LAN interface (the network we serve).
        HStack(alignment: .firstTextBaseline) {
            Text("LAN interface").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Picker("", selection: cfg.lanDevice) {
                Text("Select…").tag("")
                ForEach(shareableInterfaces.filter { $0.bsdName != net.routerConfig.uplinkDevice }) { iface in
                    Text(interfaceLabel(iface)).tag(iface.bsdName)
                }
            }
            .labelsHidden()
        }

        routerField("Router IP", cfg.routerIP, placeholder: "10.1.1.1")
        routerField("Subnet mask", cfg.subnetMask, placeholder: "255.255.255.0")

        Toggle(isOn: cfg.dhcpEnabled) {
            Text("Run a DHCP server on this network")
        }
        .toggleStyle(.checkbox)

        if net.routerConfig.dhcpEnabled {
            routerField("DHCP start", cfg.dhcpStart, placeholder: "10.1.1.100")
            routerField("DHCP end", cfg.dhcpEnd, placeholder: "10.1.1.200")
            HStack(alignment: .firstTextBaseline) {
                Text("Lease (hours)").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                TextField("24", value: Binding(
                    get: { net.routerConfig.leaseSeconds / 3600 },
                    set: { net.routerConfig.leaseSeconds = max(1, $0) * 3600 }),
                    format: .number)
                    .frame(width: 80)
            }
        }

        HStack {
            Spacer()
            if net.routerRunning {
                Button(role: .destructive) {
                    Task { await net.disableRouter() }
                } label: {
                    if net.routerBusy { ProgressView().controlSize(.small) } else { Text("Stop Router") }
                }
                .disabled(net.routerBusy)
            } else {
                Button {
                    Task { await net.enableRouter() }
                } label: {
                    if net.routerBusy { ProgressView().controlSize(.small) } else { Text("Start Router") }
                }
                .disabled(net.routerBusy
                          || net.routerConfig.uplinkDevice.isEmpty
                          || net.routerConfig.lanDevice.isEmpty)
            }
        }
    }

    private func routerField(_ label: String, _ binding: Binding<String>, placeholder: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
        }
    }

    @ViewBuilder
    private var connectedDevices: some View {
        HStack {
            Text("Connected Devices").fontWeight(.medium)
            Spacer()
            Button {
                Task { await net.refreshRouterClients() }
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh device list")
        }
        if net.routerClients.isEmpty {
            Text("No devices seen yet.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(net.routerClients) { client in
                HStack(alignment: .top) {
                    Circle()
                        .fill(client.isActive ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(client.displayName).fontWeight(.medium)
                        CopyableText(text: client.ip, font: .callout)
                        if !client.mac.isEmpty {
                            CopyableText(text: client.mac, font: .caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(client.isActive ? "Active" : "Idle")
                        .font(.caption)
                        .foregroundStyle(client.isActive ? .green : .secondary)
                }
                if client.id != net.routerClients.last?.id { Divider() }
            }
        }
    }

    /// Load the store's current sharing config into the editable draft.
    private func syncShareDraft() {
        if shareSource.isEmpty { shareSource = net.sharing.sourceDevice }
        if shareTo.isEmpty { shareTo = Set(net.sharing.toDevices) }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Flush DNS Cache") { Task { await net.flushDNS() } }
                Menu("Renew DHCP") {
                    ForEach(net.interfaces.filter { $0.isUp && $0.primaryIPv4 != nil }) { iface in
                        Button("\(iface.friendlyName) (\(iface.bsdName))") {
                            Task { await net.renewDHCP(iface.bsdName) }
                        }
                    }
                }
                .frame(width: 160)
                Button("Refresh Public IP") { Task { await net.refreshPublicIP() } }
            }
            if let msg = net.lastActionMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 6) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).textSelection(.enabled)
        }
    }

    /// An info row with a trailing "Edit" button. When `copyable` is non-nil the
    /// value is shown as a click-to-copy control instead of plain text.
    private func editableRow(_ label: String, _ value: String,
                             copyable: String? = nil, edit: @escaping () -> Void) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            if let copyable {
                CopyableText(text: value, copyValue: copyable, font: .callout)
            } else {
                Text(value).textSelection(.enabled)
            }
            Button(action: edit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Edit \(label)")
        }
    }
}

// MARK: - DNS & Gateway editors

/// Edit the DNS server list for the primary network service.
private struct DNSEditor: View {
    let current: [String]
    let service: String?
    /// The current default gateway (routers usually double as the DNS server).
    let gateway: String?
    /// Whether Internet Sharing is active (affects the guidance shown).
    var sharingOn: Bool = false
    var onSave: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DNS Servers").font(.title2.bold())
            if let service {
                Text("For “\(service)”. One address per line. Leave empty to reset to DHCP.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            guidance

            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(width: 340, height: 130)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            VStack(alignment: .leading, spacing: 4) {
                Text("Quick fill").font(.caption).foregroundStyle(.secondary)
                HStack {
                    if let gw = gateway, !gw.isEmpty {
                        Button("Router (\(gw))") { text = gw }
                    }
                    Button("Cloudflare") { text = "1.1.1.1\n1.0.0.1" }
                    Button("Google") { text = "8.8.8.8\n8.8.4.4" }
                    Button("Reset to DHCP") { text = "" }
                }
                .controlSize(.small)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let servers = text.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    onSave(servers)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { text = current.joined(separator: "\n") }
    }

    @ViewBuilder
    private var guidance: some View {
        // Warn when the router is currently the DNS server — a common setup where
        // the MikroTik/router both routes and resolves. Point out the trade-offs.
        if let gw = gateway, current.contains(gw) {
            hint(.info, "This Mac is using your router (\(gw)) for DNS. That works because the router also resolves names. If you point DNS somewhere else (e.g. Cloudflare), name lookups stop depending on the router.")
        }
        if sharingOn {
            hint(.warning, "Internet Sharing is on. The devices sharing your connection get DNS from this Mac, so changing DNS here changes it for them too.")
        }
    }
}

/// Edit the default gateway. Optionally persists a full manual IPv4 config.
private struct GatewayEditor: View {
    let current: String
    let service: String?
    /// Current DNS servers — used to warn if the gateway is also the DNS server.
    var dnsServers: [String] = []
    var sharingOn: Bool = false
    /// (gateway, ip, mask) — ip/mask empty means a temporary route change only.
    var onSave: (String, String?, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var gateway = ""
    @State private var persist = false
    @State private var ip = ""
    @State private var mask = "255.255.255.0"
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Default Gateway").font(.title2.bold())

            guidance

            Form {
                TextField("Gateway", text: $gateway, prompt: Text("192.168.1.1"))
                Toggle("Make permanent (set a manual IP config)", isOn: $persist)
                if persist {
                    TextField("IP address", text: $ip, prompt: Text("192.168.1.50"))
                    TextField("Subnet mask", text: $mask)
                    if let service {
                        Text("Writes a manual IPv4 configuration on “\(service)”. The Mac will stop using DHCP on that service.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Changes the live route now. With DHCP this reverts on the next lease renewal.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(width: 380)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(gateway.trimmingCharacters(in: .whitespaces).isEmpty
                              || (persist && ip.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { gateway = current }
        .alert("Change the gateway?", isPresented: $confirming) {
            Button("Change Gateway", role: .destructive) { commit() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Setting the wrong gateway can cut this Mac off from the network and the internet until you fix it or reconnect. Make sure \(gateway) is a router on this Mac’s subnet.")
        }
    }

    private func apply() {
        // A permanent change (or one that also drops DNS) is riskier — confirm it.
        confirming = true
    }

    private func commit() {
        if persist { onSave(gateway, ip, mask) } else { onSave(gateway, nil, nil) }
        dismiss()
    }

    @ViewBuilder
    private var guidance: some View {
        if dnsServers.contains(current), !current.isEmpty {
            hint(.info, "Your current gateway (\(current)) is also this Mac’s DNS server. If you change the gateway, name lookups may stop working until you also update DNS to match the new router.")
        }
        if sharingOn {
            hint(.warning, "Internet Sharing is on. Changing the gateway on the shared uplink can interrupt the devices connected through this Mac.")
        }
    }
}

/// Severity styling for an inline guidance hint.
private enum HintKind { case info, warning }

/// A small inline guidance banner shown inside the editors.
@ViewBuilder
private func hint(_ kind: HintKind, _ text: String) -> some View {
    let color: Color = kind == .warning ? .orange : .blue
    let icon = kind == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill"
    Label(text, systemImage: icon)
        .font(.caption)
        .foregroundStyle(.primary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.35)))
}

// MARK: - Router detail

private struct RouterDetail: View {
    let router: MikroTikRouter
    @ObservedObject var mikro: MikroTikStore
    var onEdit: () -> Void
    var onDelete: () -> Void

    /// The two panes: live status, or the WinBox-style config explorer.
    private enum Tab: String, CaseIterable { case status = "Status", configuration = "Configuration" }
    @State private var tab: Tab = .status

    private var resource: MikroTikResource? { mikro.resources[router.id] }
    private var interfaces: [MikroTikInterface] { mikro.interfaces[router.id] ?? [] }
    private var addresses: [MikroTikAddress] { mikro.addresses[router.id] ?? [] }
    private var leases: [MikroTikLease] { mikro.leases[router.id] ?? [] }
    private var error: String? { mikro.errors[router.id] }
    private var loading: Bool { mikro.loading.contains(router.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .padding(.vertical, 10)

            Divider()

            switch tab {
            case .status:
                statusPane
            case .configuration:
                MikroTikConfigView(router: router, mikro: mikro)
            }
        }
    }

    private var statusPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                }
                if let r = resource { systemSection(r) }
                if !interfaces.isEmpty { interfacesSection }
                if !addresses.isEmpty { addressesSection }
                if !leases.isEmpty { leasesSection }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(router.displayName).font(.title2.bold())
                Text(router.baseURL).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await mikro.refresh(router) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            Menu {
                Button("Edit…", action: onEdit)
                Button("Reboot Router…", role: .destructive) { Task { await mikro.reboot(router) } }
                Divider()
                Button("Remove…", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 40)
        }
    }

    private func systemSection(_ r: MikroTikResource) -> some View {
        card("System") {
            infoRow("Identity", r.identity ?? "—")
            infoRow("Model", r.boardName ?? "—")
            infoRow("RouterOS", r.version ?? "—")
            infoRow("Architecture", r.architecture ?? "—")
            infoRow("Uptime", r.uptime ?? "—")
            if let cpu = r.cpuLoad {
                HStack {
                    Text("CPU").foregroundStyle(.secondary)
                    Spacer()
                    ProgressView(value: Double(cpu), total: 100).frame(width: 120)
                    Text("\(cpu)%").monospacedDigit()
                }
            }
            if let mem = r.memoryUsedPercent {
                HStack {
                    Text("Memory").foregroundStyle(.secondary)
                    Spacer()
                    ProgressView(value: Double(mem), total: 100).frame(width: 120)
                    Text("\(mem)%").monospacedDigit()
                }
            }
        }
    }

    private var interfacesSection: some View {
        card("Interfaces") {
            ForEach(interfaces) { iface in
                HStack {
                    Circle().fill(iface.disabled ? Color.secondary : (iface.running ? Color.green : Color.orange))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(iface.name).fontWeight(.medium)
                        Text(iface.type).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { !iface.disabled },
                        set: { on in Task { await mikro.setInterface(router, interfaceID: iface.id, disabled: !on) } }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                if iface.id != interfaces.last?.id { Divider() }
            }
        }
    }

    private var addressesSection: some View {
        card("IP Addresses") {
            ForEach(addresses) { addr in
                HStack {
                    CopyableText(text: addr.address, copyValue: addr.address.components(separatedBy: "/").first ?? addr.address, font: .callout)
                    Spacer()
                    Text(addr.interface).font(.caption).foregroundStyle(.secondary)
                }
                if addr.id != addresses.last?.id { Divider() }
            }
        }
    }

    private var leasesSection: some View {
        card("DHCP Leases (\(leases.count))") {
            ForEach(leases) { lease in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(lease.hostName?.isEmpty == false ? lease.hostName! : lease.address)
                            .fontWeight(.medium)
                        HStack(spacing: 4) {
                            CopyableText(text: lease.address, font: .caption.monospaced())
                            Text("· \(lease.macAddress)")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    Spacer()
                    if let status = lease.status {
                        Text(status)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(status == "bound" ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15)))
                    }
                }
                if lease.id != leases.last?.id { Divider() }
            }
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 6) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).textSelection(.enabled)
        }
    }
}

// MARK: - Router form

private struct RouterForm: View {
    @Binding var router: MikroTikRouter
    @Binding var password: String
    let isNew: Bool
    var onSave: () -> Void
    var onCancel: () -> Void

    @State private var showPassword = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "Add MikroTik Router" : "Edit Router")
                .font(.title2.bold())

            Form {
                TextField("Name", text: $router.name, prompt: Text("Home Router"))
                TextField("Host / IP", text: $router.host, prompt: Text("192.168.88.1"))
                TextField("Username", text: $router.username)
                HStack {
                    if showPassword {
                        TextField("Password", text: $password,
                                  prompt: Text(isNew ? "" : "Leave blank to keep current"))
                    } else {
                        SecureField("Password", text: $password,
                                    prompt: Text(isNew ? "" : "Leave blank to keep current"))
                    }
                    Button { showPassword.toggle() } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
                Toggle("Use HTTPS", isOn: $router.useHTTPS)
                    .onChange(of: router.useHTTPS) { on in
                        // Snap to the conventional port when the user hasn't set a custom one.
                        if on && (router.port == 80) { router.port = 443 }
                        if !on && (router.port == 443) { router.port = 80 }
                    }
                TextField("Port", value: $router.port, format: .number.grouping(.never))
            }
            .formStyle(.grouped)

            Text("Uses the RouterOS REST API (RouterOS v7 or later). Enable it on the router with the “www-ssl” (HTTPS) or “www” (HTTP) service.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(router.host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Helpers

private struct ContentUnavailablePlaceholder: View {
    let text: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "network.slash").font(.largeTitle).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Makes the hosting macOS sheet window user-resizable so the view's flexible
/// frame max actually applies. Local copy (the ZeroTier one is private).
private struct NetworkResizableSheet: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let window = v.window {
                window.styleMask.insert(.resizable)
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
