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

/// Browse the devices (members) across all of your ZeroTier networks and connect
/// (SSH / SFTP / VNC) straight to any of their managed IP addresses. The account
/// API token is stored in the Keychain; networks and members come from the
/// ZeroTier Central API.
struct ZeroTierBrowserView: View {
    @ObservedObject var store = ZeroTierStore.shared
    @EnvironmentObject var sessions: TerminalSessionManager
    @Environment(\.dismiss) private var dismiss

    /// nil = "All networks"; otherwise a specific network id.
    @State private var selectedNetworkID: String?
    @State private var search = ""
    @State private var onlineOnly = false
    @State private var username = NSUserName()
    @State private var managingAccounts = false
    @State private var lastAction: String?

    // New-account form (in the accounts manager).
    @State private var newLabel = ""
    @State private var newToken = ""
    @State private var newServer = ""
    // Inline "edit account" editor, keyed by the account being edited.
    @State private var tokenEditAccount: UUID?
    @State private var tokenDraft = ""
    @State private var serverDraft = ""

    var body: some View {
        Group {
            if store.hasAccounts && !managingAccounts {
                browser
            } else {
                accountsManager
            }
        }
        .frame(minWidth: 780, idealWidth: 900, minHeight: 540, idealHeight: 660)
        .task { await store.loadIfNeeded() }
    }

    // MARK: - Browser

    private var browser: some View {
        VStack(spacing: 0) {
            header
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
        HStack(spacing: 10) {
            Image(systemName: "globe.americas.fill")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("ZeroTier Devices")
                    .font(.headline)
                Text("Connect to members across your ZeroTier networks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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

    // Left: the networks, grouped by account, plus an "All networks" entry.
    private var networkList: some View {
        List(selection: $selectedNetworkID) {
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
            .tag(String?.none)

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
                                .tag(Optional(network.id))
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
            Text(network.displayName)
                .lineLimit(1)
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
                    .frame(width: 160)
                Text("for SSH / SFTP").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
            Text(ip)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            connectButton("Open SSH terminal", "network") { connect(.ssh, ip: ip) }
            connectButton("Open SFTP file browser", "arrow.up.arrow.down") { connect(.sftp, ip: ip) }
            connectButton("Open VNC screen", "display") { connect(.vnc, ip: ip) }
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
            HStack(spacing: 10) {
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ZeroTier Accounts")
                        .font(.title3.weight(.semibold))
                    Text("Add one or more ZeroTier API tokens to browse their devices.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
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
        .frame(width: 540, height: 480)
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

    private enum ConnectKind { case ssh, sftp, vnc }

    private func connect(_ kind: ConnectKind, ip: String) {
        let user = username.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .ssh:
            sessions.openAdHocSSH(host: ip, port: 22, username: user, password: "")
            lastAction = "Opened an SSH terminal to \(ip)."
        case .sftp:
            sessions.openAdHocSFTP(host: ip, port: 22, username: user, password: "")
            lastAction = "Opened an SFTP browser to \(ip)."
        case .vnc:
            sessions.openAdHocVNC(host: ip, port: 5900, username: user, password: "")
            lastAction = "Opened a VNC screen to \(ip)."
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
        VStack(spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
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
