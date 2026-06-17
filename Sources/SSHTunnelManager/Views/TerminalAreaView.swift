import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The detail pane: a tab bar plus the active terminal, or a welcome screen.
struct TerminalAreaView: View {
    @EnvironmentObject var sessions: TerminalSessionManager

    var body: some View {
        VStack(spacing: 0) {
            if sessions.attachedSessions.isEmpty {
                if sessions.sessions.isEmpty {
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

private struct TabBar: View {
    @EnvironmentObject var sessions: TerminalSessionManager

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
                    }
                    Button {
                        sessions.openLocalShell()
                    } label: {
                        Image(systemName: "plus")
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderless)
                    .help("New local terminal (⌘T)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            if let session = sessions.selectedSession {
                Divider().frame(height: 22)
                SnippetsMenuButton(session: session)
                HistoryMenuButton(session: session)
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
            Image(systemName: session.kind == .ssh ? "network" : "terminal")
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

/// Lays out every attached terminal in a balanced grid (all kept live), with a
/// header per tile and a highlight on the selected one.
private struct TiledTerminalsView: View {
    @EnvironmentObject var sessions: TerminalSessionManager
    let items: [TerminalSession]

    var body: some View {
        let cols = columnCount(for: items.count)
        let rows = stride(from: 0, to: items.count, by: cols).map { start in
            Array(items[start..<min(start + cols, items.count)])
        }
        VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row) { session in
                        TerminalTile(session: session,
                                     isSelected: session.id == sessions.selectedSessionID)
                    }
                    // Pad a short final row so every tile keeps an equal width.
                    if row.count < cols {
                        ForEach(0..<(cols - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Image(systemName: session.kind == .ssh ? "network" : "terminal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(session.title)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 4)
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

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("SSH Tunnel Manager")
                    .font(.largeTitle.bold())
                Text("Open a local terminal, or pick a profile from the sidebar to start its SSH tunnels.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            HStack(spacing: 12) {
                Button {
                    sessions.openLocalShell()
                } label: {
                    Label("New Local Terminal", systemImage: "terminal")
                }
                .controlSize(.large)

                if let first = store.profiles.first {
                    Button {
                        sessions.connect(profile: first)
                    } label: {
                        Label("Connect “\(first.name)”", systemImage: "play.fill")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
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
