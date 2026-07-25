import SwiftUI

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
        PaletteRow(item: item,
                   isSelected: index == selectedIndex,
                   onEdit: item.edit,
                   onDelete: item.delete)
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
        if !item.keepsOpen { palette.isPresented = false }
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

        // User-created custom commands (editable straight from the palette).
        for command in customStore.commands {
            let subtitle = command.trimmedCommand.isEmpty
                ? command.target.label
                : "\(command.trimmedCommand) · \(command.target.label)"
            items.append(PaletteItem(
                title: command.displayTitle,
                subtitle: subtitle,
                systemImage: "wand.and.stars",
                run: { sessions.runCustomCommand(command) },
                edit: { beginEditing(command) },
                delete: { customStore.delete(id: command.id) }))
        }

        // Quick actions
        items.append(PaletteItem(title: "New Local Terminal",
                                 subtitle: "Open a shell",
                                 systemImage: "terminal") {
            sessions.openLocalShell()
        })
        items.append(PaletteItem(title: "New Finder Tab",
                                 subtitle: "Browse local files",
                                 systemImage: "folder") {
            sessions.openFinder()
        })
        items.append(PaletteItem(title: "New Text Editor",
                                 subtitle: "Edit a text or code file",
                                 systemImage: "doc.text") {
            sessions.openTextEditor()
        })
        items.append(PaletteItem(title: "New Spreadsheet",
                                 subtitle: "Open or create a CSV / TSV grid",
                                 systemImage: "tablecells") {
            sessions.openSpreadsheet()
        })
        items.append(PaletteItem(title: "Set Up Passwordless Login…",
                                 subtitle: "Copy your SSH key to any server (ssh-copy-id)",
                                 systemImage: "key") {
            sessions.setUpKeyLoginPrompt()
        })

        // Connect to profiles
        for profile in store.profiles {
            items.append(PaletteItem(title: "Connect: \(profile.name)",
                                     subtitle: profile.rowSubtitle,
                                     systemImage: profile.displayIcon) {
                sessions.connect(profile: profile)
            })
            if !profile.isLocal {
                items.append(PaletteItem(title: "SFTP: \(profile.name)",
                                         subtitle: "File transfer · \(profile.subtitle)",
                                         systemImage: "arrow.up.arrow.down") {
                    sessions.connectSFTP(profile: profile)
                })
                items.append(PaletteItem(title: "VNC: \(profile.name)",
                                         subtitle: "Screen sharing over SSH · \(profile.subtitle)",
                                         systemImage: "display") {
                    sessions.connectVNC(profile: profile)
                })
                items.append(PaletteItem(title: "Set Up Passwordless Login: \(profile.name)",
                                         subtitle: "Copy your SSH key (passwordless login) · \(profile.subtitle)",
                                         systemImage: "key") {
                    sessions.setUpKeyLogin(profile: profile)
                })
            }
        }

        // Active session's snippets
        if let session = sessions.selectedSession,
           let pid = session.profileID,
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

        // Command history across every open terminal tab (not just the active one).
        for tab in sessions.sessions where tab.supportsCommandHistory {
            for command in tab.commandHistory.reversed().prefix(30) {
                items.append(PaletteItem(title: "Run: \(command)",
                                         subtitle: "History · \(tab.title)",
                                         systemImage: "clock.arrow.circlepath") {
                    sessions.focusSession(tab)
                    tab.run(command)
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

        // Always-available action to create a new custom command. When the user has
        // typed something, offer it as the starting command text.
        let typed = query.trimmingCharacters(in: .whitespaces)
        items.append(PaletteItem(
            title: typed.isEmpty ? "New Command…" : "New Command: \(typed)",
            subtitle: "Create a reusable custom command",
            systemImage: "plus.circle",
            run: { beginEditing(CustomCommand(command: typed)) },
            keepsOpen: true))

        return items
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

