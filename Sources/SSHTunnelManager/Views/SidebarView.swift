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
    /// When on, only profiles whose host is an online ZeroTier device are shown.
    @State private var showOnlineOnly = false
    /// ZeroTier device list, observed so the online filter/glyphs update live.
    @ObservedObject private var zeroTier = ZeroTierStore.shared
    /// Group names the user has collapsed in the sidebar.
    @State private var collapsedGroups: Set<String> = []
    /// Whether the Favourites section is collapsed.
    @State private var favoritesCollapsed = false
    /// Multi-selected *row* ids (section-scoped, see `SectionedProfile.id`).
    /// Using the section-scoped id keeps identities unique even when a favourite
    /// is rendered twice, which is required for List multi-selection to work.
    @State private var multiSelection: Set<String> = []

    /// The distinct profile UUIDs currently selected (deduped across sections).
    private var selectedProfileIDs: Set<UUID> {
        Set(multiSelection.compactMap(Self.profileID(fromTag:)))
    }

    /// The distinct selected profiles, looked up fresh from the store.
    private var selectedProfiles: [SSHProfile] {
        let ids = selectedProfileIDs
        return store.profiles.filter { ids.contains($0.id) }
    }

    /// Extract the profile UUID from a section-scoped row tag.
    private static func profileID(fromTag tag: String) -> UUID? {
        guard let last = tag.split(separator: "\u{1F}").last else { return nil }
        return UUID(uuidString: String(last))
    }

    /// Profiles matching the current search text (name / host / user / group)
    /// and the online-only filter, when enabled.
    private var filteredProfiles: [SSHProfile] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return store.profiles.filter { profile in
            if showOnlineOnly && !isOnline(profile) { return false }
            guard !q.isEmpty else { return true }
            return profile.name.lowercased().contains(q)
                || profile.host.lowercased().contains(q)
                || profile.username.lowercased().contains(q)
                || profile.trimmedGroup.lowercased().contains(q)
        }
    }

    /// A profile counts as "online" when its host resolves to a ZeroTier device
    /// that's currently online, or it has a live connected session.
    private func isOnline(_ profile: SSHProfile) -> Bool {
        if sessions.isConnected(profile: profile) { return true }
        return zeroTier.member(forIP: profile.host)?.isOnline ?? false
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
            profileList
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

    private var profileList: some View {
        List(selection: $multiSelection) {
            if store.profiles.isEmpty {
                Section("Profiles") {
                    EmptyStateView(icon: "person.crop.rectangle.stack",
                                   title: "No profiles yet",
                                   message: "Click + to add one.")
                }
            } else if filteredProfiles.isEmpty {
                Section("Profiles") {
                    if showOnlineOnly && searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("No online devices")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No matches for “\(searchText)”")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                if !favoriteProfiles.isEmpty {
                    Section {
                        if !favoritesCollapsed {
                            ForEach(favoriteProfiles.map { SectionedProfile(profile: $0, section: "★") }) { item in
                                reorderableRow(item.profile, sectionKey: "★")
                            }
                            .onMove { from, to in
                                moveWithinSection(favoriteProfiles, from: from, to: to)
                            }
                        }
                    } header: {
                        favoritesHeader(count: favoriteProfiles.count)
                    }
                }
                ForEach(groupedProfiles, id: \.group) { entry in
                    Section {
                        if !collapsedGroups.contains(entry.group) {
                            ForEach(entry.profiles.map { SectionedProfile(profile: $0, section: entry.group) }) { item in
                                reorderableRow(item.profile, sectionKey: entry.group)
                            }
                            .onMove { from, to in
                                moveWithinSection(entry.profiles, from: from, to: to)
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
        .contextMenu(forSelectionType: String.self) { tags in
            let ids = Set(tags.compactMap(Self.profileID(fromTag:)))
            if ids.count > 1 {
                multiProfileContextMenu(ids)
            } else if let id = ids.first,
                      let profile = store.profiles.first(where: { $0.id == id }) {
                profileContextMenu(profile)
            }
        }
        .onChange(of: multiSelection) { _ in
            syncSelectionOut(selectedProfileIDs)
        }
        .onChange(of: selectedProfileID) { newValue in
            syncSelectionIn(newValue)
        }
        .onAppear {
            syncSelectionIn(selectedProfileID)
        }
        // Esc clears the sidebar selection (and the highlighted detail row).
        .onExitCommand {
            multiSelection = []
            selectedProfileID = nil
        }
    }

    /// Drive the detail view from the most recent single pick. When a
    /// multi-selection collapses to one row, reflect it; clear when empty.
    private func syncSelectionOut(_ newValue: Set<UUID>) {
        if newValue.count == 1, let id = newValue.first {
            if selectedProfileID != id { selectedProfileID = id }
        } else if newValue.isEmpty {
            selectedProfileID = nil
        }
    }

    /// Reflect external selection changes (e.g. after create/import). Selects
    /// every section tag that maps to the given profile so a favourite lights up
    /// in both its Favourites row and its group row.
    private func syncSelectionIn(_ newValue: UUID?) {
        guard let id = newValue else {
            if !multiSelection.isEmpty { multiSelection = [] }
            return
        }
        // If the profile is already part of the current selection, leave the
        // (possibly multi-) selection alone.
        if selectedProfileIDs.contains(id) { return }
        multiSelection = tags(for: id)
    }

    /// Every section-scoped row tag that renders the given profile id.
    private func tags(for id: UUID) -> Set<String> {
        var result: Set<String> = []
        if favoriteProfiles.contains(where: { $0.id == id }) {
            result.insert("★\u{1F}\(id.uuidString)")
        }
        for entry in groupedProfiles where entry.profiles.contains(where: { $0.id == id }) {
            result.insert("\(entry.group)\u{1F}\(id.uuidString)")
        }
        return result
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
            Button {
                showOnlineOnly.toggle()
            } label: {
                Image(systemName: showOnlineOnly ? "wifi" : "wifi.slash")
                    .foregroundStyle(showOnlineOnly ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(showOnlineOnly ? "Showing online devices only — click to show all"
                                 : "Show only online devices")
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

    /// Collapsible header for the Favourites section, with a right-click menu to
    /// connect to every favourite at once.
    private func favoritesHeader(count: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                favoritesCollapsed.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: favoritesCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                Text("Favourites")
                Spacer()
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                connectAllFavorites()
            } label: {
                Label("Connect All Favourites", systemImage: "play.fill")
            }
            .disabled(favoriteProfiles.isEmpty)
            Button {
                for profile in favoriteProfiles where sessions.isConnected(profile: profile) {
                    sessions.disconnect(profile: profile)
                }
            } label: {
                Label("Disconnect All Favourites", systemImage: "stop.fill")
            }
        }
    }

    /// Connect to every favourite profile.
    private func connectAllFavorites() {
        for profile in favoriteProfiles where !sessions.isConnected(profile: profile) {
            onConnect(profile)
        }
    }

    /// Context menu shown when multiple profiles are selected.
    @ViewBuilder
    private func multiProfileContextMenu(_ ids: Set<UUID>) -> some View {
        let profiles = store.profiles.filter { ids.contains($0.id) }
        Button {
            for profile in profiles where !sessions.isConnected(profile: profile) {
                onConnect(profile)
            }
        } label: {
            Label("Connect \(profiles.count) Profiles", systemImage: "play.fill")
        }
        Button {
            for profile in profiles where sessions.isConnected(profile: profile) {
                sessions.disconnect(profile: profile)
            }
        } label: {
            Label("Disconnect \(profiles.count) Profiles", systemImage: "stop.fill")
        }
        Divider()
        Button {
            let allFav = profiles.allSatisfy(\.isFavorite)
            for profile in profiles {
                var updated = profile
                updated.isFavorite = !allFav
                store.update(updated)
            }
        } label: {
            Label(profiles.allSatisfy(\.isFavorite) ? "Remove from Favourites" : "Add to Favourites",
                  systemImage: profiles.allSatisfy(\.isFavorite) ? "star.slash" : "star")
        }
        Button {
            ProfileTransfer.exportFlow(profiles, suggestedName: "Profiles")
        } label: {
            Label("Export \(profiles.count) Profiles…", systemImage: "square.and.arrow.up")
        }
        Divider()
        Button(role: .destructive) {
            for profile in profiles { store.delete(profile) }
        } label: {
            Label("Delete \(profiles.count) Profiles", systemImage: "trash")
        }
    }

    /// One profile row with its selection tag and right-click menu.
    @ViewBuilder
    private func profileRow(_ profile: SSHProfile, sectionKey: String) -> some View {
        ProfileRow(
            profile: profile,
            isConnected: sessions.isConnected(profile: profile),
            health: sessions.tunnelHealth(for: profile),
            onConnect: { onConnect(profile) },
            onDisconnect: { sessions.disconnect(profile: profile) }
        )
        .tag("\(sectionKey)\u{1F}\(profile.id.uuidString)")
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
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            let section = canonicalSection(for: profile)
            let idx = section.firstIndex(where: { $0.id == profile.id })
            Menu {
                Button {
                    move(profile, in: section, to: 0)
                } label: { Label("Move to Top", systemImage: "arrow.up.to.line") }
                    .disabled(idx == 0)
                Button {
                    move(profile, in: section, by: -1)
                } label: { Label("Move Up", systemImage: "arrow.up") }
                    .disabled(idx == 0)
                Button {
                    move(profile, in: section, by: 1)
                } label: { Label("Move Down", systemImage: "arrow.down") }
                    .disabled(idx == section.count - 1)
                Button {
                    move(profile, in: section, to: section.count - 1)
                } label: { Label("Move to Bottom", systemImage: "arrow.down.to.line") }
                    .disabled(idx == section.count - 1)
            } label: {
                Label("Move", systemImage: "arrow.up.arrow.down")
            }
            .disabled(section.count < 2)
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

    /// The section a profile canonically belongs to (its group), used to bound
    /// the right-click ▸ Move commands.
    private func canonicalSection(for profile: SSHProfile) -> [SSHProfile] {
        groupedProfiles.first { $0.profiles.contains { $0.id == profile.id } }?.profiles ?? []
    }

    /// Move a profile by a relative offset within its section.
    private func move(_ profile: SSHProfile, in section: [SSHProfile], by offset: Int) {
        guard let idx = section.firstIndex(where: { $0.id == profile.id }) else { return }
        move(profile, in: section, to: idx + offset)
    }

    /// Move a profile to an absolute index within its section.
    private func move(_ profile: SSHProfile, in section: [SSHProfile], to dest: Int) {
        guard let idx = section.firstIndex(where: { $0.id == profile.id }),
              section.indices.contains(dest), dest != idx else { return }
        if dest < idx {
            // Insert before the profile currently occupying the destination slot.
            store.move(id: profile.id, before: section[dest].id)
        } else {
            // Moving down: place after the destination by inserting before the
            // row just past it, or append to the end of the section.
            if dest + 1 < section.count {
                store.move(id: profile.id, before: section[dest + 1].id)
            } else if let after = section.last {
                store.move(id: after.id, before: profile.id)
            }
        }
    }

    /// A profile row wrapped with drag-to-reorder support. Dragging a row and
    /// dropping it onto another row in the **same section** reorders them (and
    /// persists the order). `.onMove` is unreliable on a macOS `.sidebar` List, so
    /// this uses explicit drag sources + a drop delegate, which the source-list
    /// backing honours. Reordering is disabled while a search filter is active
    /// (the visible rows are only a subset) — clear the search to reorder.
    @ViewBuilder
    /// A profile row. Reordering is handled by the enclosing `ForEach`'s
    /// `.onMove`, which is the native macOS mechanism and coexists with List
    /// multi-selection (unlike `.onDrag`, which steals modifier-clicks).
    private func reorderableRow(_ profile: SSHProfile, sectionKey: String) -> some View {
        profileRow(profile, sectionKey: sectionKey)
    }

    /// Persist a within-section reorder produced by `.onMove`.
    private func moveWithinSection(_ profiles: [SSHProfile], from: IndexSet, to: Int) {
        var arr = profiles
        arr.move(fromOffsets: from, toOffset: to)
        store.reorderSection(orderedIDs: arr.map(\.id))
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
                    if profile.autoConnectOnLaunch {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("Connects automatically at launch")
                    }
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
    }
}
