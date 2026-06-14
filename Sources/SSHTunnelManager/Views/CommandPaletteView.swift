import SwiftUI

/// A Spotlight-style command palette: type to filter actions across profiles,
/// the current tab's command history, snippets, and quick actions.
struct CommandPaletteView: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var sessions: TerminalSessionManager
    @ObservedObject var palette: CommandPaletteModel

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            results
        }
        .frame(width: 620)
        .background(.regularMaterial)
        .onAppear { searchFocused = true; selectedIndex = 0 }
        .onChange(of: query) { _ in selectedIndex = 0 }
        .onExitCommand { palette.isPresented = false }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search profiles, commands, snippets…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit(runSelected)
                .onMoveCommand { direction in
                    switch direction {
                    case .up:   moveSelection(-1)
                    case .down: moveSelection(1)
                    default:    break
                    }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var results: some View {
        let items = filteredItems
        if items.isEmpty {
            Text("No matches")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: 320)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { pair in
                            row(index: pair.offset, item: pair.element)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 320)
                .onChange(of: selectedIndex) { new in
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
    }

    private func row(index: Int, item: PaletteItem) -> some View {
        PaletteRow(item: item, isSelected: index == selectedIndex)
            .id(index)
            .contentShape(Rectangle())
            .onTapGesture { run(item) }
            .onHover { hovering in if hovering { selectedIndex = index } }
    }

    // MARK: - Actions / items

    private func moveSelection(_ delta: Int) {
        let count = filteredItems.count
        guard count > 0 else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }

    private func runSelected() {
        let items = filteredItems
        guard items.indices.contains(selectedIndex) else { return }
        run(items[selectedIndex])
    }

    private func run(_ item: PaletteItem) {
        palette.isPresented = false
        item.run()
    }

    /// All available actions, filtered by the search query.
    private var filteredItems: [PaletteItem] {
        let all = allItems
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
        }
    }

    private var allItems: [PaletteItem] {
        var items: [PaletteItem] = []

        // Quick actions
        items.append(PaletteItem(title: "New Local Terminal",
                                 subtitle: "Open a shell",
                                 systemImage: "terminal") {
            sessions.openLocalShell()
        })

        // Connect to profiles
        for profile in store.profiles {
            items.append(PaletteItem(title: "Connect: \(profile.name)",
                                     subtitle: profile.subtitle,
                                     systemImage: "network") {
                sessions.connect(profile: profile)
            })
        }

        // Active session's snippets + history
        if let session = sessions.selectedSession {
            if let pid = session.profileID,
               let profile = store.profiles.first(where: { $0.id == pid }) {
                for snippet in profile.snippets where !snippet.command.isEmpty {
                    let label = snippet.label.isEmpty ? snippet.command : snippet.label
                    items.append(PaletteItem(title: "Run snippet: \(label)",
                                             subtitle: snippet.command,
                                             systemImage: "text.badge.plus") {
                        session.run(snippet.command)
                    })
                }
            }
            for command in session.commandHistory.reversed().prefix(50) {
                items.append(PaletteItem(title: "Run: \(command)",
                                         subtitle: "History · \(session.title)",
                                         systemImage: "clock.arrow.circlepath") {
                    session.run(command)
                })
            }
        }

        // Disconnect all when tunnels are live
        if sessions.sessions.contains(where: { $0.kind == .ssh && $0.isRunning }) {
            items.append(PaletteItem(title: "Disconnect All Tunnels",
                                     subtitle: "Close every running SSH session",
                                     systemImage: "bolt.slash") {
                sessions.disconnectAllTunnels()
            })
        }

        return items
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .frame(width: 22)
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
