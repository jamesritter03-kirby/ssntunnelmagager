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
        .help("Pick an IP address from your ZeroTier devices")
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
            } else {
                setupForm
            }
        }
        .frame(width: 340, height: store.hasAccounts ? 430 : 300)
        .task { await store.loadIfNeeded() }
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
        if store.networks.isEmpty && store.isLoadingNetworks {
            spacerBox { ProgressView() }
        } else if devices.isEmpty {
            spacerBox {
                Text(search.isEmpty && !onlineOnly ? "No devices with an IP found." : "No matching devices.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(devices) { member in
                        deviceBlock(member)
                    }
                }
                .padding(8)
            }
        }
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
