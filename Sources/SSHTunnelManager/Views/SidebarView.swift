import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var sessions: TerminalSessionManager
    @Binding var selectedProfileID: UUID?

    var onConnect: (SSHProfile) -> Void
    var onEdit: (SSHProfile) -> Void
    var onNew: () -> Void
    var onDuplicate: (SSHProfile) -> Void

    @State private var searchText = ""
    /// Group names the user has collapsed in the sidebar.
    @State private var collapsedGroups: Set<String> = []
    /// The profile currently being dragged to reorder, if any.
    @State private var draggingProfileID: UUID?

    /// Profiles matching the current search text (name / host / user / group).
    private var filteredProfiles: [SSHProfile] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.profiles }
        return store.profiles.filter {
            $0.name.lowercased().contains(q)
                || $0.host.lowercased().contains(q)
                || $0.username.lowercased().contains(q)
                || $0.trimmedGroup.lowercased().contains(q)
        }
    }

    private var favoriteProfiles: [SSHProfile] {
        filteredProfiles.filter { $0.isFavorite }
    }

    /// Profiles grouped by their group name; named groups sorted alphabetically,
    /// the ungrouped bucket ("") last. Favourites are included here too — they
    /// appear in the Favourites section *as well as* their group, not moved out
    /// of it.
    private var groupedProfiles: [(group: String, profiles: [SSHProfile])] {
        let groups = Dictionary(grouping: filteredProfiles) { $0.trimmedGroup }
        let orderedKeys = groups.keys.sorted { a, b in
            if a.isEmpty != b.isEmpty { return !a.isEmpty }   // ungrouped last
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return orderedKeys.map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            List(selection: $selectedProfileID) {
                if store.profiles.isEmpty {
                    Section("Profiles") {
                        EmptyStateView(icon: "person.crop.rectangle.stack",
                                       title: "No profiles yet",
                                       message: "Click + to add one.")
                    }
                } else if filteredProfiles.isEmpty {
                    Section("Profiles") {
                        Text("No matches for “\(searchText)”")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if !favoriteProfiles.isEmpty {
                        Section("Favourites") {
                            ForEach(favoriteProfiles.map { SectionedProfile(profile: $0, section: "★") }) { item in
                                reorderableRow(item.profile, in: favoriteProfiles)
                            }
                        }
                    }
                    ForEach(groupedProfiles, id: \.group) { entry in
                        Section {
                            if !collapsedGroups.contains(entry.group) {
                                ForEach(entry.profiles.map { SectionedProfile(profile: $0, section: entry.group) }) { item in
                                    reorderableRow(item.profile, in: entry.profiles)
                                }
                            }
                        } header: {
                            groupHeader(entry.group, count: entry.profiles.count)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // Attach the row menu at the List level, keyed by the *actually*
            // right-clicked id, and look the profile up fresh from the store when
            // the menu opens. A per-row `.contextMenu` is memoized by SwiftUI and
            // gets recycled with stale data — which made right-click ▸ Connect use
            // the last-edited profile's values instead of the clicked row's.
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first,
                   let profile = store.profiles.first(where: { $0.id == id }) {
                    profileContextMenu(profile)
                }
            }

            Divider()

            bottomBar
        }
        .toolbar {
            ToolbarItem {
                Button(action: onNew) {
                    Label("New Profile", systemImage: "plus")
                }
                .help("Add a new profile")
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search profiles…", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// A collapsible header for a profile group (chevron + name + count).
    private func groupHeader(_ group: String, count: Int) -> some View {
        let title = group.isEmpty ? "Profiles" : group
        let collapsed = collapsedGroups.contains(group)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if collapsed { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Text(title)
                Spacer()
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One profile row with its selection tag and right-click menu.
    @ViewBuilder
    private func profileRow(_ profile: SSHProfile) -> some View {
        ProfileRow(
            profile: profile,
            isConnected: sessions.isConnected(profile: profile),
            health: sessions.tunnelHealth(for: profile),
            onConnect: { onConnect(profile) },
            onDisconnect: { sessions.disconnect(profile: profile) }
        )
        .tag(profile.id)
    }

    @ViewBuilder
    private func profileContextMenu(_ profile: SSHProfile) -> some View {
        Button {
            onConnect(profile)
        } label: {
            Label("Connect", systemImage: "play.fill")
        }
        Button {
            sessions.disconnect(profile: profile)
        } label: {
            Label("Disconnect", systemImage: "stop.fill")
        }
        .disabled(!sessions.isConnected(profile: profile))
        if !profile.isLocal {
            Button {
                sessions.connectSFTP(profile: profile)
            } label: {
                Label("Open SFTP", systemImage: "arrow.up.arrow.down")
            }
            Button {
                sessions.connectVNC(profile: profile)
            } label: {
                Label("Open VNC", systemImage: "display")
            }
            Button {
                sessions.setUpKeyLogin(profile: profile)
            } label: {
                Label("Set Up Passwordless Login…", systemImage: "key")
            }
        }
        if !profile.links.isEmpty {
            Menu {
                ForEach(profile.links) { link in
                    Button(link.displayLabel) {
                        sessions.openLink(link, profile: profile)
                    }
                    .disabled(link.normalizedURL == nil)
                }
            } label: {
                Label("Open Link", systemImage: "link")
            }
        }
        if !profile.categorizedForwards.isEmpty {
            Menu {
                ForEach(profile.categorizedForwards) { forward in
                    Button {
                        sessions.openService(forward.category,
                                             forward: forward, profile: profile)
                    } label: {
                        Label(forward.trimmedName.isEmpty
                              ? "Open \(forward.category.title) (:\(forward.listenPort))"
                              : "\(forward.trimmedName) (:\(forward.listenPort))",
                              systemImage: forward.category.symbol)
                    }
                }
            } label: {
                Label("Open Service", systemImage: "bolt.horizontal")
            }
        }
        Divider()
        Button {
            toggleFavorite(profile)
        } label: {
            Label(profile.isFavorite ? "Remove from Favourites" : "Add to Favourites",
                  systemImage: profile.isFavorite ? "star.slash" : "star")
        }
        Button {
            onEdit(profile)
        } label: {
            Label("Edit…", systemImage: "pencil")
        }
        Button {
            onDuplicate(profile)
        } label: {
            Label("Duplicate…", systemImage: "plus.square.on.square")
        }
        Button {
            ProfileTransfer.exportFlow([profile],
                                       suggestedName: ProfileTransfer.fileName(for: profile))
        } label: {
            Label("Export…", systemImage: "square.and.arrow.up")
        }
        Divider()
        Button(role: .destructive) {
            store.delete(profile)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// Flip a profile's favourite flag and persist it.
    private func toggleFavorite(_ profile: SSHProfile) {
        var updated = profile
        updated.isFavorite.toggle()
        store.update(updated)
    }

    /// A profile row wrapped with drag-to-reorder support. Dragging a row and
    /// dropping it onto another row in the **same section** reorders them (and
    /// persists the order). `.onMove` is unreliable on a macOS `.sidebar` List, so
    /// this uses explicit drag sources + a drop delegate, which the source-list
    /// backing honours. Reordering is disabled while a search filter is active
    /// (the visible rows are only a subset) — clear the search to reorder.
    @ViewBuilder
    private func reorderableRow(_ profile: SSHProfile, in section: [SSHProfile]) -> some View {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            profileRow(profile)
                .onDrag {
                    draggingProfileID = profile.id
                    return NSItemProvider(object: profile.id.uuidString as NSString)
                }
                .onDrop(of: [.text], delegate: ProfileReorderDropDelegate(
                    target: profile,
                    sectionIDs: section.map(\.id),
                    draggingID: $draggingProfileID,
                    store: store))
        } else {
            profileRow(profile)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
                Button {
                    sessions.openLocalShell()
                } label: {
                    Image(systemName: "terminal")
                }
                .help("Open a local shell (⌘T)")

                Button {
                    ZeroTierBrowserModel.shared.present()
                } label: {
                    Image(systemName: "globe.americas.fill")
                }
                .help("Browse and connect to devices on your ZeroTier networks")

                Spacer()

                Menu {
                    Button {
                        ProfileTransfer.importFlow(into: store)
                    } label: {
                        Label("Import Profiles…", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        ProfileTransfer.exportFlow(store.profiles, suggestedName: "SSH Tunnels.json")
                    } label: {
                        Label("Export All Profiles…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.profiles.isEmpty)

                    Divider()
                    Button {
                        SSHConfigImporter.importFlow(into: store)
                    } label: {
                        Label("Import from ~/.ssh/config…", systemImage: "doc.text.magnifyingglass")
                    }
                    Button {
                        KnownHostsModel.shared.present()
                    } label: {
                        Label("Manage Known Hosts…", systemImage: "checkmark.shield")
                    }

                    if let id = selectedProfileID,
                       let profile = store.profiles.first(where: { $0.id == id }) {
                        Divider()
                        Button {
                            ProfileTransfer.exportFlow([profile],
                                                       suggestedName: ProfileTransfer.fileName(for: profile))
                        } label: {
                            Label("Export “\(profile.name)”…", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Import or export profiles")

                if let id = selectedProfileID, let profile = store.profiles.first(where: { $0.id == id }) {
                    if !profile.isLocal {
                        Button {
                            sessions.connectSFTP(profile: profile)
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .help("Open SFTP file transfer for the selected profile")

                        Button {
                            sessions.connectVNC(profile: profile)
                        } label: {
                            Image(systemName: "display")
                        }
                        .help("Open VNC screen sharing (over SSH) for the selected profile")

                        Button {
                            sessions.setUpKeyLogin(profile: profile)
                        } label: {
                            Image(systemName: "key")
                        }
                        .help("Set up passwordless login (copy your SSH key with ssh-copy-id)")
                    }

                    Button {
                        onEdit(profile)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .help("Edit selected profile")
                }

                Button(action: onNew) {
                    Image(systemName: "plus")
                }
                .help("Add a new profile")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

/// Pairs a profile with the sidebar section it's rendered in, giving each row a
/// unique List identity. A favourited profile appears in BOTH the Favourites
/// section and its group; without a section-scoped id the List would see two
/// rows of identical identity (the one profile id) and mis-render or mis-animate
/// them. The `.tag(profile.id)` inside the row still drives selection, so both
/// copies highlight together when their profile is selected.
private struct SectionedProfile: Identifiable {
    let profile: SSHProfile
    let section: String
    var id: String { "\(section)\u{1F}\(profile.id.uuidString)" }
}

struct ProfileRow: View {
    let profile: SSHProfile
    var isConnected: Bool = false
    var health: TunnelHealth = .unknown
    var onConnect: () -> Void
    var onDisconnect: () -> Void = {}

    /// The status-dot colour: orange when a forwarded port isn't reachable
    /// (degraded), green otherwise.
    private var statusColor: Color {
        health == .degraded ? .orange : .green
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: profile.displayIcon)
                .foregroundStyle(.tint)
                .overlay(alignment: .bottomTrailing) {
                    if isConnected {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor),
                                                           lineWidth: 1.5))
                            .offset(x: 3, y: 2)
                            .help(health == .degraded
                                  ? "Connected — a forwarded port isn't responding"
                                  : "Connected")
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if profile.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    Text(profile.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    ZeroTierStatusGlyph(host: profile.host)
                        .font(.caption2)
                }
                Text(profile.rowSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !profile.isLocal, !profile.forwards.isEmpty {
                    Text(profile.forwards.map(\.summary).joined(separator: "  ·  "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button(action: isConnected ? onDisconnect : onConnect) {
                Image(systemName: isConnected ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(isConnected ? Color.red : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help(isConnected ? "Disconnect" : "Connect")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        // Use a *simultaneous* double-tap so it coexists with the List's own
        // single-click selection. A plain `.onTapGesture` on a List row steals the
        // click and can leave the selection stuck on the previously-selected row.
        .simultaneousGesture(TapGesture(count: 2).onEnded { onConnect() })
    }
}

/// Reorders profiles by drag-and-drop within a single sidebar section. As the
/// dragged row hovers over another row in the same section, the dragged profile
/// is moved to that row's slot live; the drop just ends the gesture. Restricted
/// to the section the drop target belongs to, so a favourite can't be dragged
/// into a group (or vice-versa) — matching how the sections are built.
private struct ProfileReorderDropDelegate: DropDelegate {
    let target: SSHProfile
    /// The ids of every row in the target's section, in display order.
    let sectionIDs: [UUID]
    @Binding var draggingID: UUID?
    let store: ProfileStore

    /// Only accept a drop from a row in the same section.
    func validateDrop(info: DropInfo) -> Bool {
        guard let draggingID else { return false }
        return sectionIDs.contains(draggingID)
    }

    func dropEntered(info: DropInfo) {
        guard let draggingID, draggingID != target.id,
              sectionIDs.contains(draggingID) else { return }
        store.move(id: draggingID, before: target.id)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}
