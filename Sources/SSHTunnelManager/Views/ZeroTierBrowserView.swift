import SwiftUI

/// Drives the ZeroTier device-browser sheet. A singleton so the welcome screen,
/// the sidebar and the **New** menu can all present it while the main window
/// hosts it. Mirrors `RemoteConnectionModel` / `VNCConnectionModel`.
final class ZeroTierBrowserModel: ObservableObject {
    static let shared = ZeroTierBrowserModel()
    private init() {}

    @Published var isPresented = false
    func present() { isPresented = true }
}

/// The left-list selection: either the combined “All Networks” view or one
/// specific network. A dedicated case (rather than `String?` with a `nil` tag)
/// keeps the “All Networks” row selectable — SwiftUI's `List` treats a `nil`
/// selection tag as “no selection”, which makes that row impossible to click
/// again once a real network has been chosen.
private enum NetworkFilter: Hashable {
    case all
    case network(String)
}

/// Browse the devices (members) across all of your ZeroTier networks and connect
/// (SSH / SFTP / VNC) straight to any of their managed IP addresses. The account
/// API token is stored in the Keychain; networks and members come from the
/// ZeroTier Central API.
struct ZeroTierBrowserView: View {
    @ObservedObject var store = ZeroTierStore.shared
    @EnvironmentObject var sessions: TerminalSessionManager
    @Environment(\.dismiss) private var dismiss

    /// The left-list selection (“All Networks” or one network).
    @State private var selection: NetworkFilter = .all
    @State private var search = ""
    @State private var onlineOnly = false
    /// The "Connect as" username, remembered across launches. Defaults to the
    /// macOS login name until the user changes it.
    @AppStorage("zeroTierConnectAsUsername") private var username = NSUserName()
    @State private var password = ""
    @State private var showPassword = false
    @State private var managingAccounts = false
    @State private var lastAction: String?
    /// Whether the “This Mac” local-networks details popover is showing.
    @State private var showLocalPopover = false
    /// A member awaiting confirmation before being deauthorized (kicked off the
    /// network). Authorizing happens immediately; deauthorizing asks first.
    @State private var memberPendingDeauth: ZeroTierMember?
    /// The network id just copied to the clipboard, to briefly show a checkmark.
    @State private var copiedNetworkID: String?

    // New-account form (in the accounts manager).
    @State private var newLabel = ""
    @State private var newToken = ""
    @State private var newServer = ""
    // Inline "edit account" editor, keyed by the account being edited.
    @State private var tokenEditAccount: UUID?
    @State private var tokenDraft = ""
    @State private var serverDraft = ""

    /// The specific network id currently selected, or nil for “All Networks”.
    private var selectedNetworkID: String? {
        if case .network(let id) = selection { return id }
        return nil
    }

    var body: some View {
        Group {
            if store.hasAccounts && !managingAccounts {
                browser
            } else {
                accountsManager
            }
        }
        // A flexible max lets the macOS sheet be dragged larger (and smaller,
        // down to the mins) instead of locking at the ideal size.
        .frame(minWidth: 780, idealWidth: 900, maxWidth: .infinity,
               minHeight: 540, idealHeight: 660, maxHeight: .infinity)
        // SwiftUI sheets are fixed-size on macOS; this makes the hosting sheet
        // window user-resizable so the frame's flexible max actually applies.
        .background(ResizableSheet())
        .task { await store.loadIfNeeded() }
        .task { await store.refreshLocalNode() }
        .onAppear { store.beginAutoRefresh() }
        .onDisappear { store.endAutoRefresh() }
        .confirmationDialog(
            memberPendingDeauth.map { "Deauthorize “\($0.displayName)”?" } ?? "Deauthorize device?",
            isPresented: Binding(get: { memberPendingDeauth != nil },
                                 set: { if !$0 { memberPendingDeauth = nil } }),
            titleVisibility: .visible
        ) {
            Button("Deauthorize", role: .destructive) {
                if let m = memberPendingDeauth {
                    Task { await store.setAuthorization(m, authorized: false) }
                }
                memberPendingDeauth = nil
            }
            Button("Cancel", role: .cancel) { memberPendingDeauth = nil }
        } message: {
            Text("This removes the device from the network — it will lose its managed IP and can no longer reach other members until re-authorized.")
        }
    }

    // MARK: - Browser

    private var browser: some View {
        VStack(spacing: 0) {
            header
            if store.localNodeAvailable {
                Divider()
                localNodeStrip
            }
            Divider()
            HStack(spacing: 0) {
                networkList
                Divider()
                memberPane
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        DialogHeader(icon: "globe.americas.fill",
                     title: "ZeroTier Devices",
                     subtitle: "Connect to members across your ZeroTier networks",
                     helpArticleID: "zerotier") {
            if store.isLoadingNetworks || !store.loadingMembers.isEmpty {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await store.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh networks and members")
            .disabled(store.isLoadingNetworks)

            Button {
                openAccountsManager()
            } label: {
                Image(systemName: "key.fill")
            }
            .help("Manage ZeroTier accounts and API tokens")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // A compact strip showing this Mac's own ZeroTier membership: the local
    // node id / online state, how many networks it's connected to vs. a member
    // of, and a popover listing them (including networks not in any account).
    private var localNodeStrip: some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer")
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("This Mac").font(.caption.weight(.semibold))
                if let addr = store.localNodeAddress, !addr.isEmpty {
                    Text(addr)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Circle()
                    .fill(store.localNodeOnline ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .help(store.localNodeOnline ? "ZeroTier is online" : "ZeroTier is offline")
            }

            statusPill(color: .green, icon: "checkmark.circle.fill",
                       text: "Connected to \(store.localConnectedCount)")
                .help("Networks this Mac is actively connected to (status OK).")
            statusPill(color: .blue, icon: "person.crop.circle.badge.checkmark",
                       text: "Member of \(store.localMemberCount)")
                .help("Networks this Mac has joined in the ZeroTier app.")

            Spacer()

            Button {
                showLocalPopover = true
            } label: {
                Label("Details", systemImage: "list.bullet")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.localMemberCount == 0)
            .popover(isPresented: $showLocalPopover, arrowEdge: .bottom) {
                localNetworksPopover
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func statusPill(color: Color, icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
    }

    private var localNetworksPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("This Mac’s ZeroTier Networks")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 2)
            if let addr = store.localNodeAddress, !addr.isEmpty {
                Text("Node \(addr) · \(store.localNodeOnline ? "online" : "offline")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            Divider()
            if store.localNetworksSorted.isEmpty {
                Text("This Mac hasn’t joined any ZeroTier networks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.localNetworksSorted, id: \.id) { net in
                            localNetworkPopoverRow(net)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 380)
    }

    private func localNetworkPopoverRow(_ net: LocalNetworkStatus) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(net.isConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(net.name.isEmpty ? net.id : net.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(net.statusText)
                        .foregroundStyle(net.isConnected ? Color.green : Color.orange)
                    Text(net.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                .font(.caption)
                if let ip = net.primaryIP {
                    CopyableText(text: ip, font: .caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.networks.contains(where: { $0.id == net.id }) {
                Button("Show") {
                    selection = .network(net.id)
                    showLocalPopover = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Show this network’s devices")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // Left: the networks, grouped by account, plus an "All networks" entry.
    private var networkList: some View {
        List(selection: $selection) {
            Label {
                HStack {
                    Text("All Networks")
                    Spacer()
                    Text("\(allMembers.count)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            } icon: {
                Image(systemName: "square.stack.3d.up")
            }
            .tag(NetworkFilter.all)

            ForEach(store.accounts) { account in
                Section(account.displayLabel) {
                    let nets = store.networks(for: account.id)
                    if nets.isEmpty {
                        Text(store.isLoadingNetworks ? "Loading…" : "No networks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(nets) { network in
                            networkRow(network)
                                .tag(NetworkFilter.network(network.id))
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: 250)
    }

    private func networkRow(_ network: ZeroTierNetwork) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(network.displayName)
                    .lineLimit(1)
                Spacer(minLength: 4)
                localBadge(for: network.id)
            }
            // The 16-hex-digit network id, click (or right-click ▸ Copy) to copy.
            Button {
                copyNetworkID(network.id)
            } label: {
                HStack(spacing: 3) {
                    Text(network.id)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: copiedNetworkID == network.id
                          ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 8))
                        .foregroundStyle(copiedNetworkID == network.id ? Color.green : Color.secondary.opacity(0.6))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to copy this network ID (\(network.id))")
            .contextMenu {
                Button {
                    copyNetworkID(network.id)
                } label: {
                    Label("Copy Network ID", systemImage: "doc.on.doc")
                }
            }
            HStack(spacing: 4) {
                Circle()
                    .fill(onlineCount(for: network.id) > 0 ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text("\(onlineCount(for: network.id)) online · \(totalCount(for: network)) total")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Copy a network id to the clipboard and briefly show a checkmark on its row.
    private func copyNetworkID(_ id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
        copiedNetworkID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedNetworkID == id { copiedNetworkID = nil }
        }
    }


    /// A small marker on a network row showing this Mac's own relationship to it:
    /// a green check when actively connected, a dashed ring when it's joined but
    /// not currently connected (e.g. awaiting authorization).
    @ViewBuilder
    private func localBadge(for networkID: String) -> some View {
        if let local = store.localStatus(for: networkID) {
            if local.isConnected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .help("This Mac is connected to this network"
                          + (local.primaryIP.map { " · \($0)" } ?? ""))
            } else {
                Image(systemName: "circle.dashed")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("This Mac is a member of this network — \(local.statusText)")
            }
        }
    }

    // Right: filter controls + the member list.
    private var memberPane: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if let error = store.lastError {
                errorBanner(error)
            }
            memberContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by name, node id or IP", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Toggle("Online only", isOn: $onlineOnly)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .fixedSize()
            }
            HStack(spacing: 8) {
                Text("Connect as").font(.caption).foregroundStyle(.secondary)
                TextField("username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onChange(of: username) { _ in loadSavedPassword() }
                    .help("The username used for SSH / SFTP connections. It's remembered for next time.")
                Group {
                    if showPassword {
                        TextField("password (optional)", text: $password)
                    } else {
                        SecureField("password (optional)", text: $password)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(showPassword ? "Hide password" : "Show password")
                Button {
                    saveOrClearPassword()
                } label: {
                    Image(systemName: "key.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Save this password to your Keychain (or clear it when empty)")
                Text("for SSH / SFTP").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear { loadSavedPassword() }
    }

    @ViewBuilder
    private var memberContent: some View {
        let members = filteredMembers
        if store.isLoadingNetworks && store.networks.isEmpty {
            centered { ProgressView("Loading networks…") }
        } else if store.networks.isEmpty {
            centered {
                emptyState("No networks", "Your ZeroTier accounts have no networks, or their tokens can’t see any.")
            }
        } else if members.isEmpty {
            centered {
                emptyState("No matching devices",
                           search.isEmpty && !onlineOnly
                           ? "This network has no members yet."
                           : "No devices match your filter.")
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(members) { member in
                        memberCard(member)
                    }
                }
                .padding(14)
            }
        }
    }

    private func memberCard(_ member: ZeroTierMember) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(member.isOnline ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 9, height: 9)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(member.displayName).font(.body.weight(.semibold))
                        if !member.authorized {
                            Text("Unauthorized")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.22), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(subtitle(for: member))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                authorizeControl(member)
            }

            if member.ipAssignments.isEmpty {
                Text("No managed IP address")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 17)
            } else {
                VStack(spacing: 6) {
                    ForEach(member.ipAssignments, id: \.self) { ip in
                        ipRow(ip)
                    }
                }
                .padding(.leading, 17)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.15)))
    }

    private func ipRow(_ ip: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "number")
                .font(.caption2)
                .foregroundStyle(.secondary)
            CopyableText(text: ip)
            Spacer()
            connectButton("Open in browser", "globe") { connect(.web, ip: ip) }
            connectButton("Open SSH terminal", "terminal") { connect(.ssh, ip: ip) }
            connectButton("Open SFTP file browser", "arrow.up.arrow.down") { connect(.sftp, ip: ip) }
            connectButton("Open VNC screen", "display") { connect(.vnc, ip: ip) }
            connectButton("Open MQTT explorer", "antenna.radiowaves.left.and.right") { connect(.mqtt, ip: ip) }
            connectButton("Open Redis browser", "cylinder.split.1x2") { connect(.redis, ip: ip) }
        }
    }

    private func connectButton(_ help: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 18)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
    }

    /// Authorize (or, with confirmation, deauthorize) a member on its network.
    @ViewBuilder
    private func authorizeControl(_ member: ZeroTierMember) -> some View {
        if store.isAuthorizing(member) {
            ProgressView().controlSize(.small)
        } else if member.authorized {
            Button {
                memberPendingDeauth = member
            } label: {
                Label("Deauthorize", systemImage: "lock.slash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.orange)
            .help("Revoke this device's access to the network")
        } else {
            Button {
                Task { await store.setAuthorization(member, authorized: true) }
            } label: {
                Label("Authorize", systemImage: "checkmark.shield")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.green)
            .help("Allow this device onto the network")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: lastAction == nil ? "info.circle" : "checkmark.circle.fill")
                .foregroundStyle(lastAction == nil ? Color.secondary : Color.green)
            Text(lastAction ?? "Connections open behind this window — close it to see your new tabs.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Accounts manager

    private var accountsManager: some View {
        VStack(spacing: 0) {
            DialogHeader(icon: "globe.americas.fill",
                         title: "ZeroTier Accounts",
                         subtitle: "Add one or more ZeroTier API tokens to browse their devices.",
                         helpArticleID: "zerotier")
                .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.hasAccounts {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Accounts")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(store.accounts) { account in
                                accountRow(account)
                            }
                        }
                    }

                    addAccountForm

                    if let error = store.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Link(destination: URL(string: "https://my.zerotier.com/account")!) {
                        Label("Create an API token at my.zerotier.com/account",
                              systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Spacer()
                Button(store.hasAccounts ? "Done" : "Cancel") {
                    if store.hasAccounts { managingAccounts = false } else { dismiss() }
                }
                .keyboardShortcut(store.hasAccounts ? .defaultAction : .cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func accountRow(_ account: ZeroTierAccount) -> some View {
        HStack(spacing: 10) {
            Image(systemName: account.isCentral ? "cloud" : "server.rack")
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                TextField("Account name", text: Binding(
                    get: { account.label },
                    set: { store.renameAccount(account.id, to: $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
                Text(account.serverDisplay)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(networkCountText(account))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Edit…") {
                tokenDraft = ""
                serverDraft = account.isCentral ? "" : account.baseURL
                tokenEditAccount = account.id
            }
            .popover(isPresented: Binding(
                get: { tokenEditAccount == account.id },
                set: { if !$0 { tokenEditAccount = nil } }
            )) {
                editAccountPopover(account)
            }

            Button(role: .destructive) {
                store.removeAccount(account.id)
            } label: {
                Image(systemName: "trash")
            }
            .help("Remove this account")
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func editAccountPopover(_ account: ZeroTierAccount) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit “\(account.displayLabel)”")
                .font(.subheadline.weight(.semibold))
            Text("Server").font(.caption).foregroundStyle(.secondary)
            TextField("Blank = ZeroTier Central", text: $serverDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            Text("New API token").font(.caption).foregroundStyle(.secondary)
            SecureField("Blank = keep current token", text: $tokenDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit { saveAccountEdit(account) }
            HStack {
                Spacer()
                Button("Cancel") { tokenEditAccount = nil }
                Button("Save") { saveAccountEdit(account) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
    }

    private var addAccountForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.hasAccounts ? "Add another account" : "Add an account")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Name (e.g. Work)", text: $newLabel)
                .textFieldStyle(.roundedBorder)
            TextField("Server URL — blank for ZeroTier Central (e.g. https://zt.example.com)",
                      text: $newServer)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                SecureField("ZeroTier API token", text: $newToken)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addNewAccount)
                Button("Add") { addNewAccount() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Self-hosting ZeroTier (e.g. ZTNET)? Enter your server’s URL above and use its API token.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Helpers

    private enum ConnectKind { case web, ssh, sftp, vnc, mqtt, redis }

    private func connect(_ kind: ConnectKind, ip: String) {
        let user = username.trimmingCharacters(in: .whitespaces)
        let pass = password
        switch kind {
        case .web:
            let encoded = ip.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? ip
            guard let url = URL(string: "http://\(encoded)") else {
                lastAction = "Couldn’t open \(ip) — not a valid address."
                return
            }
            sessions.openWeb(url: url, title: ip)
            lastAction = "Opened \(ip) in a browser tab."
        case .ssh:
            sessions.openAdHocSSH(host: ip, port: 22, username: user, password: pass)
            lastAction = "Opened an SSH terminal to \(ip)."
        case .sftp:
            sessions.openAdHocSFTP(host: ip, port: 22, username: user, password: pass)
            lastAction = "Opened an SFTP browser to \(ip)."
        case .vnc:
            sessions.openAdHocVNC(host: ip, port: 5900, username: user, password: pass)
            lastAction = "Opened a VNC screen to \(ip)."
        case .mqtt:
            sessions.openAdHocService(category: .mqtt, host: ip, port: ForwardCategory.mqtt.defaultPort,
                                      username: user, password: pass)
            lastAction = "Opened an MQTT explorer to \(ip)."
        case .redis:
            sessions.openAdHocService(category: .redis, host: ip, port: ForwardCategory.redis.defaultPort,
                                      username: user, password: pass)
            lastAction = "Opened a Redis browser to \(ip)."
        }
    }

    /// Pull a previously saved password for the current "Connect as" username
    /// out of the Keychain (or clear the field when there's nothing stored).
    private func loadSavedPassword() {
        let user = username.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else { password = ""; return }
        password = KeychainStore.shared.zeroTierPassword(for: user) ?? ""
    }

    /// Save the typed password to the Keychain for the current username, or
    /// remove any saved password when the field is empty.
    private func saveOrClearPassword() {
        let user = username.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else {
            lastAction = "Enter a username before saving a password."
            return
        }
        if password.isEmpty {
            KeychainStore.shared.deleteZeroTierPassword(for: user)
            lastAction = "Removed the saved password for “\(user).”"
        } else if KeychainStore.shared.setZeroTierPassword(password, for: user) {
            lastAction = "Saved the password for “\(user)” to your Keychain."
        } else {
            lastAction = "Couldn’t save the password to your Keychain."
        }
    }

    private func openAccountsManager() {
        newLabel = ""
        newToken = ""
        newServer = ""
        tokenEditAccount = nil
        tokenDraft = ""
        serverDraft = ""
        managingAccounts = true
    }

    private func addNewAccount() {
        guard store.addAccount(label: newLabel, token: newToken, server: newServer) else { return }
        newLabel = ""
        newToken = ""
        newServer = ""
        // Jump straight to browsing the newly added account's devices.
        managingAccounts = false
    }

    private func saveAccountEdit(_ account: ZeroTierAccount) {
        let t = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        store.updateAccount(account.id, token: t.isEmpty ? nil : t, server: serverDraft)
        tokenDraft = ""
        serverDraft = ""
        tokenEditAccount = nil
    }

    private func networkCountText(_ account: ZeroTierAccount) -> String {
        let count = store.networks(for: account.id).count
        return count == 1 ? "1 network" : "\(count) networks"
    }

    /// All cached members across every network, tagged with their network.
    private var allMembers: [ZeroTierMember] {
        store.networks.flatMap { store.membersByNetwork[$0.id] ?? [] }
    }

    /// Members for the current network selection, after the search / online filter.
    private var filteredMembers: [ZeroTierMember] {
        let base: [ZeroTierMember]
        if let id = selectedNetworkID {
            base = store.membersByNetwork[id] ?? []
        } else {
            base = allMembers
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return base.filter { member in
            if onlineOnly && !member.isOnline { return false }
            guard !q.isEmpty else { return true }
            if member.displayName.lowercased().contains(q) { return true }
            if member.nodeId.lowercased().contains(q) { return true }
            if (member.physicalAddress ?? "").lowercased().contains(q) { return true }
            if store.networkName(for: member.networkId).lowercased().contains(q) { return true }
            return member.ipAssignments.contains { $0.lowercased().contains(q) }
        }
    }

    private func subtitle(for member: ZeroTierMember) -> String {
        var parts: [String] = []
        if store.accounts.count > 1, !store.accountLabel(for: member.accountId).isEmpty {
            parts.append(store.accountLabel(for: member.accountId))
        }
        if selectedNetworkID == nil {
            parts.append(store.networkName(for: member.networkId))
        }
        parts.append(member.nodeId)
        if member.isOnline {
            parts.append("online")
        } else if let seen = member.lastSeenText {
            parts.append("seen \(seen)")
        } else {
            parts.append("never seen")
        }
        if let v = member.clientVersion, !v.isEmpty { parts.append("v\(v)") }
        return parts.joined(separator: " · ")
    }

    private func onlineCount(for networkID: String) -> Int {
        (store.membersByNetwork[networkID] ?? []).filter(\.isOnline).count
    }

    private func totalCount(for network: ZeroTierNetwork) -> Int {
        if let cached = store.membersByNetwork[network.id] { return cached.count }
        return network.totalMemberCount ?? 0
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(_ title: String, _ message: String) -> some View {
        EmptyStateView(icon: "antenna.radiowaves.left.and.right.slash",
                       title: title,
                       message: message)
            .padding(24)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error).font(.caption)
            Spacer()
            Button("Dismiss") { store.clearError() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}

/// Makes the hosting **sheet** window user-resizable. SwiftUI presents sheets on
/// macOS at their ideal size with no resize handles even when the content has a
/// flexible frame; inserting `.resizable` into the sheet window's style mask lets
/// the user drag its edges (bounded by the content's min/max frame).
private struct ResizableSheet: NSViewRepresentable {
    final class Coordinator { var didExpand = false }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.apply(to: view, coordinator: context.coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(to: nsView, coordinator: context.coordinator) }
    }

    private static func apply(to view: NSView, coordinator: Coordinator) {
        guard let window = view.window else { return }
        window.styleMask.insert(.resizable)
        guard !coordinator.didExpand, let screen = window.screen ?? NSScreen.main else { return }
        coordinator.didExpand = true
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.height = visible.height
        frame.origin.y = visible.minY
        window.setFrame(frame, display: true, animate: false)
    }
}
