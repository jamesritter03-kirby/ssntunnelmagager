import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The detail pane: a tab bar plus the active terminal, or a welcome screen.
struct TerminalAreaView: View {
    @EnvironmentObject var sessions: TerminalSessionManager

    var body: some View {
        VStack(spacing: 0) {
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
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
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
                            .padding(.horizontal, 7).padding(.vertical, 5)
                    }
                    .buttonStyle(.borderless)
                    .help("New workspace (⌘⇧N)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }

            Spacer(minLength: 0)
            savedMenu.padding(.trailing, 8)
        }
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
                    HistoryMenuButton(session: session)
                }
                LinksMenuButton(session: session)
                if session.kind != .web {
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
                Divider()
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

private struct TabChip: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject var sessions: TerminalSessionManager
    @EnvironmentObject var store: ProfileStore
    let isSelected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    var onDetach: () -> Void

    /// The profile backing this tab, if any (local shells have none).
    private var profile: SSHProfile? {
        guard let pid = session.profileID else { return nil }
        return store.profiles.first(where: { $0.id == pid })
    }

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
            if let profile,
               (!profile.snippets.isEmpty && (session.kind == .ssh || session.kind == .localShell))
               || !profile.links.isEmpty {
                Divider()
            }
            if session.kind != .web {
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

    private var statusColor: Color {
        if session.isRunning { return .green }
        if let code = session.exitCode, code != 0 { return .red }
        return .secondary
    }
}

/// Lays out every attached terminal in a resizable grid (all kept live), with a
/// header per tile and a highlight on the selected one. Uses nested split views
/// so the user can drag dividers to resize panes.
private struct TiledTerminalsView: View {
    @EnvironmentObject var sessions: TerminalSessionManager
    let items: [TerminalSession]

    var body: some View {
        let cols = columnCount(for: items.count)
        let rows: [[TerminalSession]] = stride(from: 0, to: items.count, by: cols).map { start in
            Array(items[start..<min(start + cols, items.count)])
        }
        VSplitView {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HSplitView {
                    ForEach(row) { session in
                        TerminalTile(session: session,
                                     isSelected: session.id == sessions.selectedSessionID)
                            .frame(minWidth: 200, minHeight: 120)
                    }
                }
            }
        }
        .padding(6)
    }

    /// A near-square arrangement: 2 tabs → 2 cols, 3–4 → 2 cols, 5–9 → 3 cols, …
    private func columnCount(for count: Int) -> Int {
        max(1, Int(Double(count).squareRoot().rounded(.up)))
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
