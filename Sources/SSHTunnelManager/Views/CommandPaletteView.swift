import SwiftUI

/// A named group of related palette items, used for section headers and the
/// category filter menu.
private struct PaletteSection: Identifiable {
    let title: String
    let systemImage: String
    var items: [PaletteItem]
    var id: String { title }
}

/// A Spotlight-style command palette: type to filter actions across profiles,
/// the current tab's command history, snippets, and quick actions.
struct CommandPaletteView: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var sessions: TerminalSessionManager
    @ObservedObject var palette: CommandPaletteModel
    @ObservedObject private var customStore = CustomCommandStore.shared

    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var editingCommand: CustomCommand?
    /// When non-nil, only this section's items are shown (category filter menu).
    @State private var categoryFilter: String?
    /// True only when the selection last changed via the keyboard, so the list
    /// auto-scrolls for arrow keys but not while the mouse hovers rows.
    @State private var keyboardSelection = false
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
        .onChange(of: categoryFilter) { _ in selectedIndex = 0 }
        .onExitCommand { palette.isPresented = false }
        .sheet(item: $editingCommand) { command in
            CustomCommandEditor(command: command) { editingCommand = nil }
        }
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
            categoryMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// A menu to jump straight to one category of commands.
    private var categoryMenu: some View {
        Menu {
            Button {
                categoryFilter = nil
            } label: {
                Label("All Commands", systemImage: categoryFilter == nil ? "checkmark" : "square.grid.2x2")
            }
            Divider()
            ForEach(allSections) { section in
                Button {
                    categoryFilter = section.title
                } label: {
                    Label(section.title,
                          systemImage: categoryFilter == section.title ? "checkmark" : section.systemImage)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(categoryFilter ?? "All")
                    .lineLimit(1)
            }
            .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter the palette by category")
    }

    @ViewBuilder
    private var results: some View {
        let sections = filteredSections
        let flat = flatItems
        if flat.isEmpty {
            Text("No matches")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: 340)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        // Track a running global index so keyboard selection and
                        // scrolling line up across section boundaries.
                        let indexed = indexedSections(sections)
                        ForEach(indexed, id: \.title) { section in
                            Section {
                                ForEach(section.rows, id: \.item.id) { entry in
                                    row(index: entry.index, item: entry.item)
                                }
                            } header: {
                                sectionHeader(section.title, systemImage: section.systemImage)
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(height: 340)
                .onChange(of: selectedIndex) { new in
                    // Only auto-scroll for keyboard moves, so hovering while the
                    // mouse wheel scrolls doesn't yank the list around.
                    guard keyboardSelection else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption2)
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.regularMaterial)
    }

    private func row(index: Int, item: PaletteItem) -> some View {
        PaletteRow(item: item,
                   isSelected: index == selectedIndex,
                   onEdit: item.edit,
                   onDelete: item.delete)
            .id(index)
            .contentShape(Rectangle())
            .onTapGesture { run(item) }
            .onHover { hovering in
                if hovering {
                    keyboardSelection = false
                    selectedIndex = index
                }
            }
    }

    // MARK: - Actions / items

    private func moveSelection(_ delta: Int) {
        let count = flatItems.count
        guard count > 0 else { return }
        keyboardSelection = true
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }

    private func runSelected() {
        let items = flatItems
        guard items.indices.contains(selectedIndex) else { return }
        run(items[selectedIndex])
    }

    private func run(_ item: PaletteItem) {
        if !item.keepsOpen { palette.isPresented = false }
        item.run()
    }

    /// The flat, ordered list of currently-visible items (matches the rendered
    /// order), used for keyboard navigation and running the selection.
    private var flatItems: [PaletteItem] {
        filteredSections.flatMap(\.items)
    }

    /// Assigns each visible item a stable global index for selection/scrolling.
    private func indexedSections(_ sections: [PaletteSection])
        -> [(title: String, systemImage: String, rows: [(index: Int, item: PaletteItem)])] {
        var running = 0
        return sections.map { section in
            let rows = section.items.map { item -> (index: Int, item: PaletteItem) in
                defer { running += 1 }
                return (running, item)
            }
            return (section.title, section.systemImage, rows)
        }
    }

    /// Sections after applying the search query and the category filter.
    private var filteredSections: [PaletteSection] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return allSections.compactMap { section in
            if let filter = categoryFilter, section.title != filter { return nil }
            let items = q.isEmpty ? section.items : section.items.filter {
                $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
            }
            guard !items.isEmpty else { return nil }
            return PaletteSection(title: section.title, systemImage: section.systemImage, items: items)
        }
    }

    /// All available actions, grouped into labelled sections.
    private var allSections: [PaletteSection] {
        var sections: [PaletteSection] = []

        // User-created custom commands (editable straight from the palette).
        var custom: [PaletteItem] = []
        for command in customStore.commands {
            let subtitle = command.trimmedCommand.isEmpty
                ? command.target.label
                : "\(command.trimmedCommand) · \(command.target.label)"
            custom.append(PaletteItem(
                title: command.displayTitle,
                subtitle: subtitle,
                systemImage: "wand.and.stars",
                run: { sessions.runCustomCommand(command) },
                edit: { beginEditing(command) },
                delete: { customStore.delete(id: command.id) }))
        }
        // Always offer to create a new command, seeded with any typed text.
        let typed = query.trimmingCharacters(in: .whitespaces)
        custom.append(PaletteItem(
            title: typed.isEmpty ? "New Command…" : "New Command: \(typed)",
            subtitle: "Create a reusable custom command",
            systemImage: "plus.circle",
            run: { beginEditing(CustomCommand(command: typed)) },
            keepsOpen: true))
        sections.append(PaletteSection(title: "Custom Commands", systemImage: "wand.and.stars", items: custom))

        // Quick actions
        var quick: [PaletteItem] = []
        quick.append(PaletteItem(title: "New Local Terminal",
                                 subtitle: "Open a shell",
                                 systemImage: "terminal") {
            sessions.openLocalShell()
        })
        quick.append(PaletteItem(title: "New Finder Tab",
                                 subtitle: "Browse local files",
                                 systemImage: "folder") {
            sessions.openFinder()
        })
        quick.append(PaletteItem(title: "New Text Editor",
                                 subtitle: "Edit a text or code file",
                                 systemImage: "doc.text") {
            sessions.openTextEditor()
        })
        quick.append(PaletteItem(title: "New Spreadsheet",
                                 subtitle: "Open or create a CSV / TSV grid",
                                 systemImage: "tablecells") {
            sessions.openSpreadsheet()
        })
        quick.append(PaletteItem(title: "Set Up Passwordless Login…",
                                 subtitle: "Copy your SSH key to any server (ssh-copy-id)",
                                 systemImage: "key") {
            sessions.setUpKeyLoginPrompt()
        })
        // Disconnect all when tunnels are live.
        if sessions.sessions.contains(where: { $0.kind == .ssh && $0.isRunning }) {
            quick.append(PaletteItem(title: "Disconnect All Tunnels",
                                     subtitle: "Close every running SSH session",
                                     systemImage: "bolt.slash") {
                sessions.disconnectAllTunnels()
            })
        }
        sections.append(PaletteSection(title: "Quick Actions", systemImage: "bolt", items: quick))

        // Connect to profiles
        var profiles: [PaletteItem] = []
        for profile in store.profiles {
            profiles.append(PaletteItem(title: "Connect: \(profile.name)",
                                        subtitle: profile.rowSubtitle,
                                        systemImage: profile.displayIcon) {
                sessions.connect(profile: profile)
            })
            if !profile.isLocal {
                profiles.append(PaletteItem(title: "SFTP: \(profile.name)",
                                            subtitle: "File transfer · \(profile.subtitle)",
                                            systemImage: "arrow.up.arrow.down") {
                    sessions.connectSFTP(profile: profile)
                })
                profiles.append(PaletteItem(title: "VNC: \(profile.name)",
                                            subtitle: "Screen sharing over SSH · \(profile.subtitle)",
                                            systemImage: "display") {
                    sessions.connectVNC(profile: profile)
                })
                profiles.append(PaletteItem(title: "Set Up Passwordless Login: \(profile.name)",
                                            subtitle: "Copy your SSH key (passwordless login) · \(profile.subtitle)",
                                            systemImage: "key") {
                    sessions.setUpKeyLogin(profile: profile)
                })
            }
        }
        if !profiles.isEmpty {
            sections.append(PaletteSection(title: "Profiles", systemImage: "person.crop.rectangle.stack", items: profiles))
        }

        // Active session's snippets
        if let session = sessions.selectedSession,
           let pid = session.profileID,
           let profile = store.profiles.first(where: { $0.id == pid }) {
            var snippets: [PaletteItem] = []
            for snippet in profile.snippets where !snippet.command.isEmpty {
                let label = snippet.label.isEmpty ? snippet.command : snippet.label
                snippets.append(PaletteItem(title: "Run snippet: \(label)",
                                            subtitle: snippet.command,
                                            systemImage: "text.badge.plus") {
                    session.run(snippet.command)
                })
            }
            if !snippets.isEmpty {
                sections.append(PaletteSection(title: "Snippets", systemImage: "text.badge.plus", items: snippets))
            }
        }

        // Command history across every open terminal tab (not just the active one).
        var history: [PaletteItem] = []
        for tab in sessions.sessions where tab.supportsCommandHistory {
            for command in tab.commandHistory.reversed().prefix(30) {
                history.append(PaletteItem(title: "Run: \(command)",
                                           subtitle: "History · \(tab.title)",
                                           systemImage: "clock.arrow.circlepath") {
                    sessions.focusSession(tab)
                    tab.run(command)
                })
            }
        }
        if !history.isEmpty {
            sections.append(PaletteSection(title: "History", systemImage: "clock.arrow.circlepath", items: history))
        }

        return sections
    }

    // MARK: - Custom command editing

    private func beginEditing(_ command: CustomCommand) {
        // Keep the palette open behind the editor sheet.
        editingCommand = command
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

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
            if onEdit != nil || onDelete != nil {
                HStack(spacing: 4) {
                    if let onEdit {
                        rowButton("pencil", help: "Edit command", action: onEdit)
                    }
                    if let onDelete {
                        rowButton("trash", help: "Delete command", action: onDelete)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func rowButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Create or edit a single user-defined command palette command.
private struct CustomCommandEditor: View {
    @State var command: CustomCommand
    let onClose: () -> Void

    @ObservedObject private var store = CustomCommandStore.shared
    @FocusState private var nameFocused: Bool

    private var isExisting: Bool { store.commands.contains { $0.id == command.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isExisting ? "Edit Command" : "New Command")
                .font(.title3).bold()

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. Tail system log", text: $command.title)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Command").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $command.command)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3)))
            }

            Picker("Run in", selection: $command.target) {
                ForEach(CustomCommandTarget.allCases) { target in
                    Text(target.label).tag(target)
                }
            }
            .pickerStyle(.radioGroup)

            HStack {
                if isExisting {
                    Button(role: .destructive) {
                        store.delete(id: command.id)
                        onClose()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.update(command)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!command.isValid)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { nameFocused = true }
    }
}

