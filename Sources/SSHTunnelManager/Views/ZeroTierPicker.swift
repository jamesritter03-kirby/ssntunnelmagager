import SwiftUI

/// A small globe button placed next to a host/IP field. Tapping it opens a
/// popover listing your ZeroTier devices and their IP addresses; choosing an IP
/// fills the field. Lets you connect to a ZeroTier member from anywhere you'd
/// normally type a host.
struct ZeroTierPickerButton: View {
    /// Called with the chosen IP address.
    var onPick: (String) -> Void

    @ObservedObject private var store = ZeroTierStore.shared
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
            Task { await store.loadIfNeeded() }
        } label: {
            Image(systemName: "globe.americas.fill")
        }
        .buttonStyle(.borderless)
        .help("Pick an IP from your ZeroTier devices or the Mac router's clients")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ZeroTierIPPickerPopover { ip in
                onPick(ip)
                showing = false
            }
        }
    }
}

/// The popover body: a compact, filterable list of ZeroTier devices and their
/// IP addresses. Choosing an IP calls `onPick`. When no account exists yet it
/// shows an inline add-account form so the field stays usable without leaving.
private struct ZeroTierIPPickerPopover: View {
    var onPick: (String) -> Void

    @ObservedObject private var store = ZeroTierStore.shared
    @ObservedObject private var net = NetworkStore.shared
    @State private var search = ""
    @State private var onlineOnly = false
    @State private var newLabel = ""
    @State private var newToken = ""
    @State private var newServer = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.hasAccounts {
                controls
                Divider()
                content
            } else if !filteredRouterClients.isEmpty {
                // No ZeroTier account, but we're a router with clients — still
                // useful to show those.
                controls
                Divider()
                content
            } else {
                setupForm
            }
        }
        .frame(width: 340, height: (store.hasAccounts || !filteredRouterClients.isEmpty) ? 430 : 300)
        .task {
            await store.loadIfNeeded()
            await net.refreshRouterClients()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe.americas.fill").foregroundStyle(.tint)
            Text("ZeroTier Devices").font(.subheadline.weight(.semibold))
            Spacer()
            if store.isLoadingNetworks || !store.loadingMembers.isEmpty {
                ProgressView().controlSize(.small)
            } else if store.hasAccounts {
                Button { Task { await store.refreshAll() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField("Filter by name or IP", text: $search).textFieldStyle(.plain)
            Toggle("Online", isOn: $onlineOnly)
                .toggleStyle(.switch).controlSize(.mini).fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        let devices = filteredMembers
        let routerClients = filteredRouterClients
        if store.networks.isEmpty && store.isLoadingNetworks && routerClients.isEmpty {
            spacerBox { ProgressView() }
        } else if devices.isEmpty && routerClients.isEmpty {
            spacerBox {
                Text(search.isEmpty && !onlineOnly ? "No devices with an IP found." : "No matching devices.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if !routerClients.isEmpty {
                        sectionLabel("On This Mac’s Router (\(net.routerConfig.routerIP))")
                        ForEach(routerClients) { client in
                            routerClientRow(client)
                        }
                        if !devices.isEmpty {
                            Divider().padding(.vertical, 4)
                            sectionLabel("ZeroTier Devices")
                        }
                    }
                    ForEach(devices) { member in
                        deviceBlock(member)
                    }
                }
                .padding(8)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 2)
    }

    private func routerClientRow(_ client: RouterClient) -> some View {
        Button { onPick(client.ip) } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(client.isActive ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(client.displayName).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(client.ip).font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.right.circle").foregroundStyle(.tint)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
    }

    private func deviceBlock(_ member: ZeroTierMember) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(member.isOnline ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(member.displayName).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                if store.accounts.count > 1, !store.accountLabel(for: member.accountId).isEmpty {
                    Text(store.accountLabel(for: member.accountId))
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .padding(.horizontal, 4)
            HStack(spacing: 4) {
                Image(systemName: "globe").font(.system(size: 8)).foregroundStyle(.secondary)
                Text(store.networkName(for: member.networkId))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 4)
            ForEach(member.ipAssignments, id: \.self) { ip in
                Button { onPick(ip) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "number").font(.caption2).foregroundStyle(.secondary)
                        Text(ip).font(.system(.caption, design: .monospaced))
                        Spacer()
                        Image(systemName: "arrow.right.circle").foregroundStyle(.tint)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
    }

    private var setupForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a ZeroTier account").font(.subheadline.weight(.semibold))
            Text("Paste a ZeroTier API token to browse device IPs. It’s saved to your Keychain.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name (optional)", text: $newLabel).textFieldStyle(.roundedBorder)
            TextField("Server URL — blank for ZeroTier Central", text: $newServer)
                .textFieldStyle(.roundedBorder)
            SecureField("ZeroTier API token", text: $newToken)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addAccount)
            if let error = store.lastError {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
            HStack {
                Link("Get a token", destination: URL(string: "https://my.zerotier.com/account")!)
                    .font(.caption2)
                Spacer()
                Button("Add") { addAccount() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func addAccount() {
        guard store.addAccount(label: newLabel, token: newToken, server: newServer) else { return }
        newLabel = ""
        newToken = ""
        newServer = ""
    }

    private func spacerBox<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack { Spacer(); content(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Router LAN clients (only when the Mac router is running), filtered by the
    /// same search box. Online (ARP-active) devices sort first.
    private var filteredRouterClients: [RouterClient] {
        guard net.routerRunning else { return [] }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return net.routerClients
            .filter { c in
                guard !q.isEmpty else { return true }
                if c.displayName.lowercased().contains(q) { return true }
                if c.ip.lowercased().contains(q) { return true }
                return c.mac.lowercased().contains(q)
            }
            .sorted { ($0.isActive ? 0 : 1, $0.ip) < ($1.isActive ? 0 : 1, $1.ip) }
    }

    /// Devices that have at least one IP, after the search / online filter,
    /// across every account's networks.
    private var filteredMembers: [ZeroTierMember] {
        let all = store.networks.flatMap { store.membersByNetwork[$0.id] ?? [] }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { member in
            if member.ipAssignments.isEmpty { return false }
            if onlineOnly && !member.isOnline { return false }
            guard !q.isEmpty else { return true }
            if member.displayName.lowercased().contains(q) { return true }
            if member.nodeId.lowercased().contains(q) { return true }
            if store.networkName(for: member.networkId).lowercased().contains(q) { return true }
            return member.ipAssignments.contains { $0.lowercased().contains(q) }
        }
    }
}

/// A small online/offline indicator shown when a host is a known ZeroTier device
/// IP (e.g. one chosen from the ZeroTier picker next to a host field). A green
/// globe means the device has checked in recently; a grey globe means it's
/// offline. Renders nothing when the host isn't a ZeroTier IP — or the device
/// list hasn't loaded — so ordinary hosts are left unmarked.
struct ZeroTierStatusGlyph: View {
    let host: String
    @ObservedObject private var store = ZeroTierStore.shared
    @ObservedObject private var net = NetworkStore.shared

    var body: some View {
        if let member = store.member(forIP: host) {
            Image(systemName: "globe.americas.fill")
                .foregroundStyle(member.isOnline ? Color.green : Color.secondary)
                .help(helpText(for: member))
                .accessibilityLabel(member.isOnline
                                    ? "ZeroTier device online"
                                    : "ZeroTier device offline")
        } else if let client = net.routerClient(forIP: host) {
            Image(systemName: "globe.americas.fill")
                .foregroundStyle(client.isActive ? Color.green : Color.secondary)
                .help(helpText(for: client))
                .accessibilityLabel(client.isActive
                                    ? "Mac router device online"
                                    : "Mac router device offline")
        }
    }

    private func helpText(for client: RouterClient) -> String {
        if client.isActive {
            return "“\(client.displayName)” is connected to this Mac’s router"
        }
        return "“\(client.displayName)” has a lease on this Mac’s router but isn’t currently reachable"
    }

    private func helpText(for member: ZeroTierMember) -> String {
        if member.isOnline {
            return "ZeroTier device “\(member.displayName)” is online"
        }
        if let seen = member.lastSeenText {
            return "ZeroTier device “\(member.displayName)” is offline — last seen \(seen)"
        }
        return "ZeroTier device “\(member.displayName)” is offline"
    }
}
