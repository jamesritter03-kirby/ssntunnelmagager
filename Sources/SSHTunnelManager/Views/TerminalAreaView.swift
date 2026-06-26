import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The detail pane: a tab bar plus the active terminal, or a welcome screen.
struct TerminalAreaView: View {
    @EnvironmentObject var sessions: TerminalSessionManager

    var body: some View {
        VStack(spacing: 0) {
            // The workspace switcher used to live in the window title bar as a
            // `.principal` toolbar item, but those intermittently vanish when the
            // window loses and regains key focus (e.g. switching to a detached
            // terminal window and back). An ordinary slim row is reliable.
            WorkspaceBar()
            Divider()
            if sessions.attachedSessions.isEmpty {
                if sessions.currentWorkspaceSessions.isEmpty {
                    WelcomeView()
                } else {
                    AllDetachedView()
                }
            } else {
                TabBar()
                Divider()
                // Keep ALL terminals mounted (so background tunnels stay alive).
                // Tiled: lay them out in a grid. Single: stack them and show only
                // the selected one.
                if sessions.isTiled && sessions.attachedSessions.count > 1 {
                    TiledTerminalsView(items: sessions.attachedSessions)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // SwiftUI's split views cache their NSSplitView divider /
                        // row state. Without a stable identity that changes when the
                        // tile set does, switching from a 2-tile workspace to a
                        // 4-tile one would reuse the old 2-pane layout. Re-key on the
                        // workspace + its tab ids so the grid is rebuilt correctly.
                        .id(tiledLayoutID)
                } else {
                    ZStack {
                        ForEach(sessions.attachedSessions) { session in
                            TerminalContainer(session: session)
                                .opacity(session.id == sessions.selectedSessionID ? 1 : 0)
                                .allowsHitTesting(session.id == sessions.selectedSessionID)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// A stable identity for the tiled grid that changes whenever the current
    /// workspace or its set/order of attached tabs changes — forcing the split
    /// views to rebuild instead of reusing a stale pane layout.
    private var tiledLayoutID: String {
        let ids = sessions.attachedSessions.map(\.id.uuidString).joined(separator: ",")
        return "\(sessions.currentWorkspaceID.uuidString):\(ids)"
    }
}

/// The top-level bar of "workspace" tabs — each a saveable collection of
/// terminal / browser tabs. Lets the user switch, add, rename, close and save
/// workspaces, and reopen previously saved ones.
private struct WorkspaceBar: View {
    @EnvironmentObject var sessions: TerminalSessionManager

    @State private var renamingID: UUID?
    @State private var nameField = ""
    @State private var isSaving = false
    @State private var saveField = ""

    var body: some View {
        HStack(spacing: 6) {
            ForEach(sessions.workspaces) { ws in
                WorkspacePill(
                    workspace: ws,
                    isCurrent: ws.id == sessions.currentWorkspaceID,
                    tabCount: sessions.tabCount(in: ws.id),
                    canClose: sessions.workspaces.count > 1,
                    onSelect: { sessions.switchWorkspace(to: ws.id) },
                    onClose: { sessions.closeWorkspace(ws.id) },
                    onRename: { beginRename(ws) },
                    onSave: { beginSave(ws) }
                )
            }
            Button { sessions.addWorkspace() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("New workspace (⌘⇧N)")

            savedMenu
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
        .alert("Rename Workspace", isPresented: renamingBinding) {
            TextField("Name", text: $nameField)
            Button("Cancel", role: .cancel) { renamingID = nil }
            Button("Rename") {
                if let id = renamingID { sessions.renameWorkspace(id, to: nameField) }
                renamingID = nil
            }
        }
        .alert("Save Workspace", isPresented: $isSaving) {
            TextField("Name", text: $saveField)
            Button("Cancel", role: .cancel) { isSaving = false }
            Button("Save") {
                sessions.saveCurrentWorkspace(name: saveField)
                isSaving = false
            }
        } message: {
            Text("Save this workspace's tabs so you can reopen them later from the workspaces menu.")
        }
    }

    private var savedMenu: some View {
        Menu {
            Button {
                beginSave(sessions.currentWorkspace)
            } label: {
                Label("Save Current Workspace…", systemImage: "square.and.arrow.down")
            }
            if !sessions.savedWorkspaces.isEmpty {
                Section("Open Saved Workspace") {
                    ForEach(sessions.savedWorkspaces) { saved in
                        Button {
                            sessions.openSavedWorkspace(saved)
                        } label: {
                            Label("\(saved.name) (\(saved.tabs.count))",
                                  systemImage: "square.stack.3d.up.fill")
                        }
                    }
                }
                Menu {
                    ForEach(sessions.savedWorkspaces) { saved in
                        Button(role: .destructive) {
                            sessions.deleteSavedWorkspace(saved.id)
                        } label: {
                            Label(saved.name, systemImage: "trash")
                        }
                    }
                } label: {
                    Label("Delete Saved Workspace", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "square.stack.3d.up.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Save or open workspaces")
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })
    }

    private func beginRename(_ ws: Workspace) {
        nameField = ws.name
        renamingID = ws.id
    }

    private func beginSave(_ ws: Workspace?) {
        saveField = ws?.name ?? ""
        isSaving = true
    }
}

/// One workspace "pill" in the workspace bar.
private struct WorkspacePill: View {
    let workspace: Workspace
    let isCurrent: Bool
    let tabCount: Int
    let canClose: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    var onRename: () -> Void
    var onSave: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .font(.caption2)
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
            Text(workspace.name)
                .font(.callout.weight(isCurrent ? .semibold : .regular))
                .lineLimit(1)
            Text("\(tabCount)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.18)))
            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help("Close workspace")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(isCurrent ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isCurrent ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Rename…", action: onRename)
            Button("Save as Workspace…", action: onSave)
            if canClose {
                Divider()
                Button("Close Workspace", role: .destructive, action: onClose)
            }
        }
    }
}

private struct TabBar: View {
    @EnvironmentObject var sessions: TerminalSessionManager
    @EnvironmentObject var store: ProfileStore

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sessions.attachedSessions) { session in
                        TabChip(
                            session: session,
                            isSelected: session.id == sessions.selectedSessionID,
                            onSelect: { sessions.select(session) },
                            onClose: { sessions.close(session) },
                            onDetach: { DetachedTerminalController.shared.detach(session) }
                        )
                        .onDrag {
                            NSItemProvider(object: session.id.uuidString as NSString)
                        }
                        .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                            guard let provider = providers.first else { return false }
                            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                                guard let idString = object as? String,
                                      let uuid = UUID(uuidString: idString),
                                      let fromIndex = sessions.attachedSessions.firstIndex(where: { $0.id == uuid }),
                                      let toIndex = sessions.attachedSessions.firstIndex(where: { $0.id == session.id }),
                                      fromIndex != toIndex else { return }
                                DispatchQueue.main.async {
                                    sessions.moveAttachedSession(from: fromIndex, to: toIndex)
                                }
                            }
                            return true
                        }
                    }
                    Menu {
                        Button {
                            sessions.openLocalShell()
                        } label: {
                            Label("New Local Terminal", systemImage: "terminal")
                        }
                        Button {
                            sessions.openBlankWeb()
                        } label: {
                            Label("New Browser Tab", systemImage: "globe")
                        }
                        Button {
                            sessions.openFinder()
                        } label: {
                            Label("New Finder Tab", systemImage: "folder")
                        }
                        Divider()
                        Button {
                            ServiceConnectionModel.shared.present(.mqtt)
                        } label: {
                            Label("New MQTT Connection…", systemImage: ForwardCategory.mqtt.symbol)
                        }
                        Button {
                            ServiceConnectionModel.shared.present(.redis)
                        } label: {
                            Label("New Redis Connection…", systemImage: ForwardCategory.redis.symbol)
                        }
                        if !store.profiles.isEmpty {
                            Divider()
                            Menu {
                                ForEach(store.profiles) { profile in
                                    Button {
                                        sessions.connect(profile: profile)
                                    } label: {
                                        Label(profile.name, systemImage: profile.displayIcon)
                                    }
                                }
                            } label: {
                                Label("Connect to Profile", systemImage: "network")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("New tab — terminal, browser, or a profile connection")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            if let session = sessions.selectedSession {
                Divider().frame(height: 22)
                if session.kind == .ssh || session.kind == .localShell {
                    SnippetsMenuButton(session: session)
                }
                if session.supportsCommandHistory {
                    HistoryMenuButton(session: session)
                }
                LinksMenuButton(session: session)
                if session.kind != .web && session.kind != .finder {
                    DisconnectButton(session: session)
                }
            }

            Divider().frame(height: 22)
            Button {
                sessions.isTiled.toggle()
            } label: {
                Image(systemName: sessions.isTiled ? "square" : "rectangle.split.2x2")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .disabled(sessions.attachedSessions.count < 2)
            .help(sessions.isTiled ? "Show one tab at a time" : "Tile all tabs side by side")
        }
        .background(.bar)
    }
}

/// A drop-down of the active profile's saved commands; click one to insert it.
private struct SnippetsMenuButton: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject var store: ProfileStore

    private var snippets: [CommandSnippet] {
        guard let pid = session.profileID,
              let profile = store.profiles.first(where: { $0.id == pid }) else { return [] }
        return profile.snippets
    }

    var body: some View {
        if !snippets.isEmpty {
            Menu {
                ForEach(snippets) { snippet in
                    Menu(snippet.label.isEmpty ? snippet.command : snippet.label) {
                        Button("Run") { session.run(snippet.command) }
                        Button("Insert at Prompt") { session.paste(snippet.command) }
                    }
                    .disabled(!session.isRunning || snippet.command.isEmpty)
                }
            } label: {
                Image(systemName: "text.badge.plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.leading, 8)
            .help("Insert a saved command into the terminal")
        }
    }
}

/// A drop-down of the active profile's saved links; click one to open it in an
/// in-app browser tab.
private struct LinksMenuButton: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var sessions: TerminalSessionManager

    private var profile: SSHProfile? {
        guard let pid = session.profileID else { return nil }
        return store.profiles.first(where: { $0.id == pid })
    }

    var body: some View {
        if let profile, !profile.links.isEmpty {
            Menu {
                ForEach(profile.links) { link in
                    Button {
                        sessions.openLink(link, profile: profile)
                    } label: {
                        Label(link.displayLabel, systemImage: "globe")
                    }
                    .disabled(link.normalizedURL == nil)
                }
            } label: {
                Image(systemName: "globe")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.leading, 8)
            .help("Open a saved link in a browser tab")
        }
    }
}

/// A drop-down of the selected tab's previous commands; click one to run it again.
private struct HistoryMenuButton: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        Menu {
            if session.commandHistory.isEmpty {
                Text("No commands yet")
            } else {
                ForEach(Array(session.commandHistory.reversed().prefix(40).enumerated()), id: \.offset) { entry in
                    Button(displayTitle(entry.element)) {
                        session.rerun(entry.element)
                    }
                    .disabled(!session.isRunning)
                }
            }
            Divider()
            // Import is always available (even with no history yet) so a tab can
            // be seeded from an exported file or a shell's own history.
            Button("Import History…") {
                importHistory()
            }
            if !session.commandHistory.isEmpty {
                Button("Save History…") {
                    saveHistory()
                }
                Button("Clear History", role: .destructive) {
                    session.clearHistory()
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Command history — click a command to run it again")
    }

    private func displayTitle(_ command: String) -> String {
        command.count > 60 ? String(command.prefix(59)) + "…" : command
    }
    /// Write the tab's command history to a user-chosen text file.
    private func saveHistory() {
        let panel = NSSavePanel()
        panel.title = "Save Command History"
        panel.nameFieldStringValue = session.suggestedHistoryFileName
        panel.allowedContentTypes = [.plainText]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try session.historyExportText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Load commands from a user-chosen text file into this tab's history. Accepts
    /// files exported by Save History… as well as plain shell history files
    /// (`.bash_history`, `.zsh_history`); hidden files are shown so those dotfiles
    /// can be picked.
    private func importHistory() {
        let panel = NSOpenPanel()
        panel.title = "Import Command History"
        panel.message = "Choose a text file with one command per line (an exported history file, or a shell's .bash_history / .zsh_history)."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // `.data` lets extensionless dotfiles be selected; we decode as text and
        // tolerate non-UTF-8 bytes, so a non-text file just yields no commands.
        panel.allowedContentTypes = [.plainText, .text, .data]
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Lossy UTF-8 decode never throws, so zsh's meta-encoded bytes don't
            // abort the import; only a genuine read error (permissions) does.
            let data = try Data(contentsOf: url)
            let text = String(decoding: data, as: UTF8.self)
            let added = session.importHistory(fromText: text)
            reportImport(added: added)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Tell the user how many commands were imported (or that none were found).
    private func reportImport(added: Int) {
        let alert = NSAlert()
        if added > 0 {
            alert.alertStyle = .informational
            alert.messageText = "Imported \(added) command\(added == 1 ? "" : "s")"
            alert.informativeText = "They're now in this tab's history — click the clock to run any of them again."
        } else {
            alert.alertStyle = .warning
            alert.messageText = "No commands imported"
            alert.informativeText = "That file didn't contain any commands (after skipping blank and comment lines)."
        }
        alert.runModal()
    }
}

/// Disconnects the selected tab's process (closing its SSH tunnel) while keeping
/// the tab open so it can be reconnected. Disabled once the session has ended.
private struct DisconnectButton: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        Button {
            session.disconnect()
        } label: {
            Image(systemName: "bolt.horizontal.circle")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .disabled(!session.isRunning)
        .help(session.isRemote
              ? "Disconnect this tunnel (you can reconnect)"
              : "Stop this terminal (you can restart it)")
    }
}

/// The shared right-click menu for a terminal tab. Used both by the tab chip in
/// the tab bar and by the header bar of a tile in the tiled layout, so a tile's
/// title bar offers the very same actions (Snippets, Links, Disconnect/Stop,
/// SFTP, VNC, Detach, Close) as right-clicking its tab.
private struct TerminalTabContextMenu: View {
    @EnvironmentObject var sessions: TerminalSessionManager
    @EnvironmentObject var store: ProfileStore
    @ObservedObject var session: TerminalSession
    var onDetach: () -> Void
    var onClose: () -> Void

    /// The profile backing this tab, if any (local shells have none).
    private var profile: SSHProfile? {
        guard let pid = session.profileID else { return nil }
        return store.profiles.first(where: { $0.id == pid })
    }

    /// "Open Redis (:6379)" style label for a categorized forward.
    private func serviceMenuLabel(_ forward: PortForward) -> String {
        let suffix = forward.localEndpoint.map { " (:\($0.port))" } ?? ""
        return "Open \(forward.category.title)\(suffix)"
    }

    var body: some View {
        // Snippets submenu (terminal tabs only)
        if let profile, !profile.snippets.isEmpty,
           session.kind == .ssh || session.kind == .localShell {
            Menu {
                ForEach(profile.snippets) { snippet in
                    Menu(snippet.label.isEmpty ? snippet.command : snippet.label) {
                        Button("Run") { session.run(snippet.command) }
                        Button("Insert at Prompt") { session.paste(snippet.command) }
                    }
                    .disabled(!session.isRunning || snippet.command.isEmpty)
                }
            } label: {
                Label("Snippets", systemImage: "text.badge.plus")
            }
        }
        // Links submenu (any tab whose profile has links)
        if let profile, !profile.links.isEmpty {
            Menu {
                ForEach(profile.links) { link in
                    Button {
                        sessions.openLink(link, profile: profile)
                    } label: {
                        Label(link.displayLabel, systemImage: "globe")
                    }
                    .disabled(link.normalizedURL == nil)
                }
            } label: {
                Label("Links", systemImage: "globe")
            }
        }
        // Services submenu (categorized forwards → Web / MQTT / Redis tabs)
        if let profile, !profile.categorizedForwards.isEmpty {
            Menu {
                ForEach(profile.categorizedForwards) { forward in
                    Button {
                        sessions.openService(forward.category, forward: forward, profile: profile)
                    } label: {
                        Label(serviceMenuLabel(forward), systemImage: forward.category.symbol)
                    }
                }
            } label: {
                Label("Services", systemImage: "square.grid.2x2")
            }
        }
        if let profile,
           (!profile.snippets.isEmpty && (session.kind == .ssh || session.kind == .localShell))
           || !profile.links.isEmpty || !profile.categorizedForwards.isEmpty {
            Divider()
        }
        if session.kind != .web && session.kind != .finder {
            Button {
                session.disconnect()
            } label: {
                Label(session.isRemote ? "Disconnect" : "Stop",
                      systemImage: "bolt.horizontal.circle")
            }
            .disabled(!session.isRunning)
        }
        if let profile, !profile.isLocal, session.kind != .sftp {
            Button {
                sessions.connectSFTP(profile: profile)
            } label: {
                Label("Open SFTP", systemImage: "arrow.up.arrow.down")
            }
        }
        if let profile, !profile.isLocal, session.kind != .vnc {
            Button {
                sessions.connectVNC(profile: profile)
            } label: {
                Label("Open VNC", systemImage: "display")
            }
        }
        if let profile, !profile.isLocal {
            Button {
                sessions.setUpKeyLogin(profile: profile)
            } label: {
                Label("Set Up Key Login…", systemImage: "key")
            }
        }
        if session.kind == .localShell {
            Button {
                sessions.setUpKeyLoginPrompt()
            } label: {
                Label("Set Up Passwordless Login…", systemImage: "key")
            }
        }
        Button {
            onDetach()
        } label: {
            Label("Detach into New Window", systemImage: "macwindow.badge.plus")
        }
        Divider()
        Button(role: .destructive) {
            onClose()
        } label: {
            Label("Close Tab", systemImage: "xmark")
        }
    }
}

private struct TabChip: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    var onDetach: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Image(systemName: session.symbolName)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(session.title)
                .lineLimit(1)
                .font(.callout)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Close tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            TerminalTabContextMenu(session: session, onDetach: onDetach, onClose: onClose)
        }
    }

    private var statusColor: Color {
        if session.isRunning { return .green }
        if let code = session.exitCode, code != 0 { return .red }
        return .secondary
    }
}

/// Lays out every attached terminal in a resizable grid (all kept live), with a
/// header per tile and a highlight on the selected one. The user can drag the
/// dividers to resize panes; the sizes are stored as fractions on the workspace
/// (`TileLayout`) so they're remembered when switching workspaces and across
/// launches. The layout scales with the window because everything is fractional.
private struct TiledTerminalsView: View {
    @EnvironmentObject var sessions: TerminalSessionManager
    let items: [TerminalSession]

    /// While a divider drag is in progress, the previewed layout. It drives only
    /// the guide line — not the tiles — so the live terminals don't re-lay-out on
    /// every pixel. `nil` when not dragging.
    @State private var dragLayout: TileLayout?
    /// The layout captured when the current drag began; the drag's translation is
    /// applied relative to this so the guide tracks the pointer exactly.
    @State private var dragAnchor: TileLayout?
    /// Which divider is being dragged (drives the guide line and keeps the source
    /// divider highlighted). `nil` when not dragging.
    @State private var activeDivider: ActiveDivider?

    /// Identifies the divider under the drag: a boundary between two rows, or a
    /// boundary between two columns within a given row.
    private enum ActiveDivider: Equatable {
        case row(Int)
        case column(row: Int, boundary: Int)
    }

    private let dividerThickness: CGFloat = 8
    private let minTileWidth: CGFloat = 160
    private let minTileHeight: CGFloat = 110

    private var shape: [Int] { TileGrid.shape(forCount: items.count) }

    var body: some View {
        let shape = self.shape
        let rows = TileGrid.rows(items, shape: shape)
        // The committed layout always drives the tile frames, so the live
        // terminals only re-lay-out once — when the drag ends — instead of on
        // every pixel of the drag (which made the panes and divider flicker). The
        // in-progress drag is shown with a lightweight guide line instead.
        let committed = sessions.currentTileLayout.conformed(to: shape)
        GeometryReader { geo in
            let availableHeight = max(1, geo.size.height
                                      - dividerThickness * CGFloat(max(0, rows.count - 1)))
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        tileRow(rowIndex: rowIndex, row: row, layout: committed,
                                totalWidth: geo.size.width)
                            .frame(height: CGFloat(committed.rowFractions[rowIndex]) * availableHeight)

                        if rowIndex < rows.count - 1 {
                            TileDivider(orientation: .horizontal,
                                        isActive: activeDivider == .row(rowIndex))
                                .frame(height: dividerThickness)
                                .gesture(rowDrag(boundary: rowIndex, shape: shape,
                                                 availableHeight: availableHeight))
                        }
                    }
                }
                dragGuide(committed: committed, geo: geo, availableHeight: availableHeight)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(6)
    }

    /// One row of the grid: its tiles separated by draggable vertical dividers.
    private func tileRow(rowIndex: Int, row: [TerminalSession],
                         layout: TileLayout, totalWidth: CGFloat) -> some View {
        let columns = row.count
        let availableWidth = max(1, totalWidth
                                 - dividerThickness * CGFloat(max(0, columns - 1)))
        return HStack(spacing: 0) {
            ForEach(Array(row.enumerated()), id: \.element.id) { columnIndex, session in
                TerminalTile(session: session,
                             isSelected: session.id == sessions.selectedSessionID)
                    .frame(width: CGFloat(layout.columnFractions[rowIndex][columnIndex]) * availableWidth)

                if columnIndex < columns - 1 {
                    TileDivider(orientation: .vertical,
                                isActive: activeDivider == .column(row: rowIndex, boundary: columnIndex))
                        .frame(width: dividerThickness)
                        .gesture(columnDrag(row: rowIndex, boundary: columnIndex,
                                            shape: shape, availableWidth: availableWidth))
                }
            }
        }
    }

    /// The highlighted guide line shown at the divider's would-be position during
    /// a drag. Its position comes from the previewed layout; the tiles themselves
    /// don't move until the drag ends, so nothing re-lays-out per pixel.
    @ViewBuilder
    private func dragGuide(committed: TileLayout, geo: GeometryProxy,
                           availableHeight: CGFloat) -> some View {
        if let activeDivider, let preview = dragLayout {
            switch activeDivider {
            case .row(let index):
                let y = horizontalDividerCenter(preview, boundary: index,
                                                availableHeight: availableHeight)
                Capsule().fill(Color.accentColor)
                    .frame(width: max(0, geo.size.width), height: 2)
                    .position(x: geo.size.width / 2, y: y)
            case .column(let rowIndex, let boundary):
                let x = verticalDividerCenter(preview, row: rowIndex, boundary: boundary,
                                              totalWidth: geo.size.width)
                let extent = rowExtent(committed, row: rowIndex, availableHeight: availableHeight)
                Capsule().fill(Color.accentColor)
                    .frame(width: 2, height: max(0, extent.height))
                    .position(x: x, y: extent.top + extent.height / 2)
            }
        }
    }

    /// Drag gesture for the horizontal divider that resizes rows `index`/`index+1`.
    private func rowDrag(boundary index: Int, shape: [Int],
                         availableHeight: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                activeDivider = .row(index)
                let anchor = anchorLayout(for: shape)
                let minFraction = Double(minTileHeight / availableHeight)
                let delta = Double(value.translation.height / availableHeight)
                var next = anchor
                next.rowFractions = TileLayout.resized(anchor.rowFractions, boundary: index,
                                                       by: delta, minFraction: minFraction)
                dragLayout = next
            }
            .onEnded { _ in commitDrag() }
    }

    /// Drag gesture for a vertical divider that resizes columns `index`/`index+1`
    /// within `rowIndex`.
    private func columnDrag(row rowIndex: Int, boundary index: Int,
                            shape: [Int], availableWidth: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                activeDivider = .column(row: rowIndex, boundary: index)
                let anchor = anchorLayout(for: shape)
                let minFraction = Double(minTileWidth / availableWidth)
                let delta = Double(value.translation.width / availableWidth)
                var next = anchor
                next.columnFractions[rowIndex] = TileLayout.resized(
                    anchor.columnFractions[rowIndex], boundary: index,
                    by: delta, minFraction: minFraction)
                dragLayout = next
            }
            .onEnded { _ in commitDrag() }
    }

    /// The layout a drag is measured against — captured once when the drag starts.
    private func anchorLayout(for shape: [Int]) -> TileLayout {
        if let dragAnchor { return dragAnchor }
        let anchor = (dragLayout ?? sessions.currentTileLayout).conformed(to: shape)
        dragAnchor = anchor
        return anchor
    }

    /// Commit the in-progress drag to the workspace (a single resize) and end it.
    private func commitDrag() {
        if let dragLayout { sessions.updateTileLayout(dragLayout) }
        dragLayout = nil
        dragAnchor = nil
        activeDivider = nil
    }

    /// Sum of the first `index + 1` fractions (0 for a negative index).
    private func cumulative(_ fractions: [Double], through index: Int) -> CGFloat {
        guard index >= 0 else { return 0 }
        return CGFloat(fractions.prefix(index + 1).reduce(0, +))
    }

    /// Center Y of the horizontal divider after row `index`, for layout `L`.
    private func horizontalDividerCenter(_ L: TileLayout, boundary index: Int,
                                         availableHeight: CGFloat) -> CGFloat {
        cumulative(L.rowFractions, through: index) * availableHeight
            + CGFloat(index) * dividerThickness + dividerThickness / 2
    }

    /// Center X of the vertical divider after column `boundary` in row `row`.
    private func verticalDividerCenter(_ L: TileLayout, row: Int, boundary: Int,
                                       totalWidth: CGFloat) -> CGFloat {
        let columns = L.columnFractions[row].count
        let availableWidth = max(1, totalWidth - dividerThickness * CGFloat(max(0, columns - 1)))
        return cumulative(L.columnFractions[row], through: boundary) * availableWidth
            + CGFloat(boundary) * dividerThickness + dividerThickness / 2
    }

    /// Top and height of row `row` — the cross-axis extent for a vertical guide.
    private func rowExtent(_ L: TileLayout, row: Int,
                           availableHeight: CGFloat) -> (top: CGFloat, height: CGFloat) {
        let top = cumulative(L.rowFractions, through: row - 1) * availableHeight
            + CGFloat(row) * dividerThickness
        let height = CGFloat(L.rowFractions[row]) * availableHeight
        return (top, height)
    }
}

/// A thin draggable separator between tiles, with a subtle line that brightens on
/// hover and a matching resize cursor. The drag gesture itself is supplied by the
/// grid, which knows the geometry and which panes to resize.
private struct TileDivider: View {
    enum Orientation { case horizontal, vertical }
    let orientation: Orientation
    /// True while this divider is being dragged — keeps it highlighted without
    /// depending on hover, which flickers as the pointer leaves during a drag.
    var isActive: Bool = false
    @State private var hovering = false

    private var lineOpacity: Double {
        if isActive { return 0.5 }
        return hovering ? 0.6 : 0.18
    }

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .overlay(
                Rectangle()
                    .fill(Color.secondary.opacity(lineOpacity))
                    .frame(width: orientation == .vertical ? 1 : nil,
                           height: orientation == .horizontal ? 1 : nil)
            )
            // AppKit cursor rect — it balances enter/exit reliably even if the
            // divider is torn down mid-hover (e.g. when the grid rebuilds), unlike
            // manual NSCursor push/pop which could leave a stuck resize cursor.
            .overlay(ResizeCursorRect(orientation: orientation))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Shows the appropriate resize cursor over its bounds via an AppKit cursor rect.
private struct ResizeCursorRect: NSViewRepresentable {
    let orientation: TileDivider.Orientation

    func makeNSView(context: Context) -> CursorRectView {
        let view = CursorRectView()
        view.cursor = orientation == .horizontal ? .resizeUpDown : .resizeLeftRight
        return view
    }

    func updateNSView(_ nsView: CursorRectView, context: Context) {
        nsView.cursor = orientation == .horizontal ? .resizeUpDown : .resizeLeftRight
    }

    final class CursorRectView: NSView {
        var cursor: NSCursor = .arrow {
            didSet {
                if cursor != oldValue { window?.invalidateCursorRects(for: self) }
            }
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    }
}

/// One terminal in tiled view: a slim header (status, title, detach, close) above
/// the live terminal, framed and click-to-select.
private struct TerminalTile: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject var sessions: TerminalSessionManager
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Image(systemName: session.symbolName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(session.title)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if session.supportsCommandHistory {
                    HistoryMenuButton(session: session)
                        .font(.caption2)
                        .menuIndicator(.hidden)
                }
                if session.isRunning {
                    Button {
                        session.disconnect()
                    } label: {
                        Image(systemName: "bolt.horizontal.circle").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help(session.isRemote ? "Disconnect this tunnel" : "Stop this terminal")
                }
                Button {
                    DetachedTerminalController.shared.detach(session)
                } label: {
                    Image(systemName: "macwindow.badge.plus").font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Detach into new window")
                Button {
                    sessions.close(session)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help("Close tab")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)
            .contentShape(Rectangle())
            .onTapGesture { sessions.select(session) }
            .contextMenu {
                TerminalTabContextMenu(
                    session: session,
                    onDetach: { DetachedTerminalController.shared.detach(session) },
                    onClose: { sessions.close(session) })
            }

            Divider()
            TerminalContainer(session: session)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.8)
                                         : Color.secondary.opacity(0.25),
                              lineWidth: isSelected ? 2 : 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusColor: Color {
        if session.isRunning { return .green }
        if let code = session.exitCode, code != 0 { return .red }
        return .secondary
    }
}

struct TerminalContainer: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject var sessions: TerminalSessionManager

    var body: some View {
        if session.kind == .sftp {
            SFTPBrowserView(session: session)
        } else if session.kind == .vnc {
            VNCConsoleView(session: session)
        } else if session.kind == .web {
            WebTabView(session: session)
        } else if session.kind == .mqtt {
            MQTTExplorerView(session: session)
        } else if session.kind == .redis {
            RedisBrowserView(session: session)
        } else if session.kind == .finder {
            FinderBrowserView(session: session)
        } else {
            terminal
        }
    }

    private var terminal: some View {
        ZStack(alignment: .top) {
            TerminalViewRepresentable(session: session)
                .id(session.id)

            if !session.isRunning {
                ExitBanner(
                    session: session,
                    onReconnect: { session.restart() },
                    onClose: { sessions.close(session) }
                )
                .padding(10)
            }
        }
    }
}

private struct ExitBanner: View {
    @ObservedObject var session: TerminalSession
    var onReconnect: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(exitText).fontWeight(.semibold)
                Text(session.commandPreview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Reconnect", action: onReconnect)
                .buttonStyle(.borderedProminent)
            Button("Close", action: onClose)
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8, y: 2)
    }

    private var exitText: String {
        if let code = session.exitCode, code != 0 {
            return "Session ended — exit code \(code)"
        }
        return "Session ended"
    }
}

private struct WelcomeView: View {
    @EnvironmentObject var sessions: TerminalSessionManager
    @EnvironmentObject var store: ProfileStore

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 280), spacing: 10)]

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                Text("SSH Tunnel Manager")
                    .font(.largeTitle.bold())
                Text("Resume your last session, open a local terminal, or click a profile to connect.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            HStack(spacing: 12) {
                let saved = sessions.savedSessionCount
                if saved > 0 && sessions.sessions.isEmpty {
                    Button {
                        sessions.restoreSavedSessions()
                    } label: {
                        Label("Resume Last Session (\(saved) tab\(saved == 1 ? "" : "s"))",
                              systemImage: "arrow.clockwise.circle.fill")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .help("Reopen the tabs that were open when you last quit")
                }
                Button {
                    sessions.openLocalShell()
                } label: {
                    Label("New Local Terminal", systemImage: "terminal")
                }
                .controlSize(.large)

                Button {
                    sessions.openBlankWeb()
                } label: {
                    Label("New Browser Tab", systemImage: "globe")
                }
                .controlSize(.large)

                Button {
                    sessions.openFinder()
                } label: {
                    Label("New Finder Tab", systemImage: "folder")
                }
                .controlSize(.large)

                Menu {
                    Button {
                        ServiceConnectionModel.shared.present(.mqtt)
                    } label: {
                        Label("New MQTT Connection…", systemImage: ForwardCategory.mqtt.symbol)
                    }
                    Button {
                        ServiceConnectionModel.shared.present(.redis)
                    } label: {
                        Label("New Redis Connection…", systemImage: ForwardCategory.redis.symbol)
                    }
                } label: {
                    Label("New Connection", systemImage: "bolt.horizontal.circle")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.large)
                .fixedSize()
            }

            if !store.profiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Profiles")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(store.profiles) { profile in
                                ProfileLaunchButton(profile: profile)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 280)
                }
                .frame(maxWidth: 580)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

/// A clickable card on the welcome screen that connects a profile. Right-click
/// for SFTP / VNC on remote profiles.
private struct ProfileLaunchButton: View {
    @EnvironmentObject var sessions: TerminalSessionManager
    let profile: SSHProfile

    var body: some View {
        Button {
            sessions.connect(profile: profile)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: profile.displayIcon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(profile.rowSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                sessions.connect(profile: profile)
            } label: {
                Label("Connect", systemImage: "play.fill")
            }
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
                    Label("Set Up Key Login…", systemImage: "key")
                }
            }
        }
        .help(profile.isLocal ? "Open this local profile" : "Connect this SSH tunnel")
    }
}

/// Shown when every open terminal has been detached into its own window.
private struct AllDetachedView: View {
    @EnvironmentObject var sessions: TerminalSessionManager

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 46))
                .foregroundStyle(.tint)
            Text("All terminals are in separate windows")
                .font(.title3.weight(.semibold))
            Text("\(sessions.detachedSessionIDs.count) detached window(s) — their tunnels are still running. Close a window to bring its tab back, or open a new terminal here.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button {
                sessions.openLocalShell()
            } label: {
                Label("New Local Terminal", systemImage: "terminal")
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
