import Foundation
import SwiftUI
import AppKit
import Combine

/// Owns the open terminal tabs and routes "open shell" / "connect profile" actions.
final class TerminalSessionManager: ObservableObject {
    @Published var sessions: [TerminalSession] = []

    /// The open workspaces (the big top-level tabs). Always at least one.
    @Published var workspaces: [Workspace]
    /// The workspace currently shown in the main window.
    @Published var currentWorkspaceID: UUID
    /// Named collections of tabs the user saved to reopen later.
    @Published private(set) var savedWorkspaces: [SavedWorkspace] = []

    static let shared = TerminalSessionManager()

    private init() {
        let tiled = UserDefaults.standard.bool(forKey: "tileTerminals")
        let first = Workspace(name: "Workspace 1", isTiled: tiled)
        workspaces = [first]
        currentWorkspaceID = first.id
        loadSavedWorkspaces()
    }

    // MARK: - Current workspace

    /// The workspace currently shown (falls back to the first if out of sync).
    var currentWorkspace: Workspace? {
        workspaces.first { $0.id == currentWorkspaceID } ?? workspaces.first
    }

    private var currentIndex: Int? {
        workspaces.firstIndex { $0.id == currentWorkspaceID }
    }

    /// The selected tab within the current workspace.
    var selectedSessionID: UUID? {
        get { currentWorkspace?.selectedSessionID }
        set { if let i = currentIndex { workspaces[i].selectedSessionID = newValue } }
    }

    var selectedSession: TerminalSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    /// IDs of sessions currently shown in their own floating window.
    @Published var detachedSessionIDs: Set<UUID> = []

    /// Whether the current workspace tiles its tabs in a grid. Per-workspace, with
    /// the last-used value remembered as the default for new workspaces.
    var isTiled: Bool {
        get { currentWorkspace?.isTiled ?? false }
        set {
            if let i = currentIndex { workspaces[i].isTiled = newValue }
            UserDefaults.standard.set(newValue, forKey: "tileTerminals")
        }
    }

    /// The saved sizing of the current workspace's tiled grid.
    var currentTileLayout: TileLayout { currentWorkspace?.tileLayout ?? TileLayout() }

    /// Record a new tiled-grid layout for the current workspace (after the user
    /// drags a divider). Stored on the workspace, so it's persisted with
    /// resume-last-session and survives switching workspaces.
    func updateTileLayout(_ layout: TileLayout) {
        guard let i = currentIndex, workspaces[i].tileLayout != layout else { return }
        workspaces[i].tileLayout = layout
    }

    /// Every session in the current workspace, in tab order (detached included).
    var currentWorkspaceSessions: [TerminalSession] {
        guard let ws = currentWorkspace else { return [] }
        return ws.tabIDs.compactMap { id in sessions.first { $0.id == id } }
    }

    /// Sessions shown as tabs in the current workspace (everything not detached).
    var attachedSessions: [TerminalSession] {
        currentWorkspaceSessions.filter { !detachedSessionIDs.contains($0.id) }
    }

    /// Number of live tabs in a workspace (for the workspace pill badge).
    func tabCount(in workspaceID: UUID) -> Int {
        guard let ws = workspaces.first(where: { $0.id == workspaceID }) else { return 0 }
        return ws.tabIDs.filter { id in sessions.contains { $0.id == id } }.count
    }

    // MARK: - Workspace operations

    func addWorkspace() {
        let tiled = UserDefaults.standard.bool(forKey: "tileTerminals")
        let ws = Workspace(name: nextWorkspaceName(), isTiled: tiled)
        workspaces.append(ws)
        currentWorkspaceID = ws.id
    }

    private func nextWorkspaceName() -> String {
        var n = workspaces.count + 1
        let existing = Set(workspaces.map { $0.name })
        while existing.contains("Workspace \(n)") { n += 1 }
        return "Workspace \(n)"
    }

    func switchWorkspace(to id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        currentWorkspaceID = id
    }

    func selectNextWorkspace() {
        guard let i = currentIndex, workspaces.count > 1 else { return }
        currentWorkspaceID = workspaces[(i + 1) % workspaces.count].id
    }

    func selectPreviousWorkspace() {
        guard let i = currentIndex, workspaces.count > 1 else { return }
        currentWorkspaceID = workspaces[(i - 1 + workspaces.count) % workspaces.count].id
    }

    func renameWorkspace(_ id: UUID, to name: String) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { workspaces[i].name = trimmed }
    }

    /// Close a workspace and every tab it holds. The last workspace can't close.
    func closeWorkspace(_ id: UUID) {
        guard workspaces.count > 1,
              let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let removingCurrent = (currentWorkspaceID == id)
        let tabIDs = workspaces[i].tabIDs
        // Dropping the sessions tears down their PTYs / tunnels; the detached-window
        // observer closes any floating windows that were showing them.
        sessions.removeAll { tabIDs.contains($0.id) }
        for sid in tabIDs { detachedSessionIDs.remove(sid) }
        workspaces.remove(at: i)
        if removingCurrent {
            let newIndex = min(i, workspaces.count - 1)
            currentWorkspaceID = workspaces[newIndex].id
        }
    }

    /// Open a new tab running the user's login shell.
    func openLocalShell() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let session = TerminalSession(
            kind: .localShell,
            title: "Terminal",
            executable: shell,
            args: ["-l"],
            commandPreview: "\(shell) -l",
            theme: TerminalTheme.theme(id: AppSettings.shared.defaultThemeID),
            fontSize: AppSettings.shared.defaultFontSize
        )
        addAndStart(session)
    }

    /// Open a new tab running `ssh` with the profile's tunnel configuration —
    /// or, for a **local** profile, a login shell starting in its folder.
    func connect(profile: SSHProfile) {
        if profile.isLocal { connectLocalProfile(profile); return }
        // A profile's tunnel binds fixed forwarded ports, so a second identical
        // tunnel can't bind them (ssh runs with ExitOnForwardFailure=yes) and dies
        // the instant it connects. If one is already running, reveal it instead of
        // launching a doomed duplicate — which is what made reconnecting look broken.
        if let existing = sessions.first(where: {
            $0.profileID == profile.id && $0.kind == .ssh && $0.isRunning
        }) {
            reveal(existing)
            return
        }
        let args = SSHCommandBuilder.arguments(for: profile)
        let session = TerminalSession(
            kind: .ssh,
            title: profile.name,
            executable: SSHCommandBuilder.sshPath,
            args: args,
            commandPreview: SSHCommandBuilder.commandPreview(for: profile),
            profileID: profile.id,
            theme: TerminalTheme.theme(id: profile.theme),
            fontSize: profile.fontSize,
            autofillPassword: KeychainStore.shared.hasPassword(for: profile.id),
            requireAuthForPassword: profile.requireAuthForSavedPassword
        )
        addAndStart(session)
    }

    /// Open a local login shell for a `isLocal` profile, starting in `startPath`.
    private func connectLocalProfile(_ profile: SSHProfile) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let trimmed = profile.startPath.trimmingCharacters(in: .whitespaces)
        let dir = trimmed.isEmpty ? nil : (trimmed as NSString).expandingTildeInPath
        let preview = dir.map { "cd \(SSHCommandBuilder.shellQuote($0)) && \(shell) -l" }
            ?? "\(shell) -l"
        let session = TerminalSession(
            kind: .localShell,
            title: profile.name,
            executable: shell,
            args: ["-l"],
            commandPreview: preview,
            profileID: profile.id,
            theme: TerminalTheme.theme(id: profile.theme),
            fontSize: profile.fontSize,
            startDirectory: dir
        )
        addAndStart(session)
    }

    /// Open a new tab running an interactive `sftp` file-transfer session for the
    /// profile (same host / auth as a normal connection).
    func connectSFTP(profile: SSHProfile) {
        let args = SFTPCommandBuilder.arguments(for: profile)
        let session = TerminalSession(
            kind: .sftp,
            title: "\(profile.name) — SFTP",
            executable: SFTPCommandBuilder.sftpPath,
            args: args,
            commandPreview: SFTPCommandBuilder.commandPreview(for: profile),
            profileID: profile.id,
            theme: TerminalTheme.theme(id: profile.theme),
            fontSize: profile.fontSize,
            autofillPassword: KeychainStore.shared.hasPassword(for: profile.id),
            requireAuthForPassword: profile.requireAuthForSavedPassword
        )
        addAndStart(session)
    }

    /// Open a new tab that tunnels VNC over SSH (a local port-forward to the
    /// server's screen) and launches macOS Screen Sharing through it.
    func connectVNC(profile: SSHProfile) {
        let localPort = VNCCommandBuilder.freeLocalPort()
        let args = VNCCommandBuilder.arguments(for: profile, localPort: localPort)
        let session = TerminalSession(
            kind: .vnc,
            title: "\(profile.name) — VNC",
            executable: VNCCommandBuilder.sshPath,
            args: args,
            commandPreview: VNCCommandBuilder.commandPreview(for: profile, localPort: localPort),
            profileID: profile.id,
            theme: TerminalTheme.theme(id: profile.theme),
            fontSize: profile.fontSize,
            autofillPassword: KeychainStore.shared.hasPassword(for: profile.id),
            requireAuthForPassword: profile.requireAuthForSavedPassword
        )
        addAndStart(session)
    }

    /// Bring an existing session into view: switch to the workspace that holds it
    /// and select it, or focus its floating window if it's detached.
    private func reveal(_ session: TerminalSession) {
        if detachedSessionIDs.contains(session.id) {
            DetachedTerminalController.shared.detach(session)   // focuses the window
            return
        }
        if let ws = workspaces.first(where: { $0.tabIDs.contains(session.id) }) {
            currentWorkspaceID = ws.id
            selectedSessionID = session.id
        }
    }

    private func addAndStart(_ session: TerminalSession) {
        sessions.append(session)
        if let i = currentIndex {
            workspaces[i].tabIDs.append(session.id)
            workspaces[i].selectedSessionID = session.id
        }
        // Start on the next runloop turn so the view is mounted with a real size.
        DispatchQueue.main.async {
            session.start()
        }
    }

    /// Open a saved profile link in an in-app browser tab. Ensures the profile's
    /// SSH tunnel is running first, and routes through its SOCKS proxy if it has a
    /// dynamic (`-D`) forward — so links that depend on the tunnel actually work.
    func openLink(_ link: ProfileLink, profile: SSHProfile? = nil) {
        guard let url = link.normalizedURL else { return }
        let title = link.displayLabel.isEmpty ? (url.host ?? "Web") : link.displayLabel
        var proxy: WebProxy? = nil
        if let profile, !profile.isLocal {
            ensureConnected(profile)
            if let s = profile.socksProxy { proxy = WebProxy(host: s.host, port: s.port) }
        }
        openWeb(url: url, title: title, profileID: profile?.id, proxy: proxy)
    }

    /// Open an arbitrary URL in an in-app browser tab.
    func openWeb(url: URL, title: String, profileID: UUID? = nil, proxy: WebProxy? = nil) {
        let session = TerminalSession(
            kind: .web,
            title: title,
            executable: "",
            args: [],
            commandPreview: url.absoluteString,
            profileID: profileID,
            webURL: url,
            webProxy: proxy
        )
        addAndStart(session)
    }

    /// Open a blank in-app browser tab the user can type any URL into.
    func openBlankWeb() {
        let session = TerminalSession(
            kind: .web,
            title: "New Tab",
            executable: "",
            args: [],
            commandPreview: "",
            webURL: nil
        )
        addAndStart(session)
    }

    /// Start a profile's SSH tunnel if one isn't already running, so links that
    /// rely on its port forwards work. The tunnel opens as its own visible tab so
    /// any password / host-key prompt can be answered.
    func ensureConnected(_ profile: SSHProfile) {
        guard !profile.isLocal else { return }
        let running = sessions.contains {
            $0.profileID == profile.id && $0.kind == .ssh && $0.isRunning
        }
        if !running { connect(profile: profile) }
    }

    func close(_ session: TerminalSession) {
        guard sessions.contains(where: { $0.id == session.id }) else { return }
        // Pick the neighbouring tab (next, else previous) within its workspace so
        // selection lands somewhere sensible after the close.
        let wsIndex = workspaces.firstIndex { $0.tabIDs.contains(session.id) }
        var neighborID: UUID?
        if let w = wsIndex {
            let attachedIDs = workspaces[w].tabIDs.filter { !detachedSessionIDs.contains($0) }
            if let pos = attachedIDs.firstIndex(of: session.id) {
                neighborID = attachedIDs[(pos + 1)...].first ?? attachedIDs[..<pos].last
            }
        }
        // Kill the child process *now* rather than waiting for ARC to drop the last
        // reference and let the PTY teardown deliver SIGHUP. A lingering strong
        // reference (a still-mounted SwiftUI view, a capturing closure) would leave
        // an SSH tunnel running as a "zombie" that keeps holding its forwarded ports,
        // so the next connection to that profile collides on them and dies.
        session.shutDown()
        sessions.removeAll { $0.id == session.id }
        detachedSessionIDs.remove(session.id)
        if let w = wsIndex {
            workspaces[w].tabIDs.removeAll { $0 == session.id }
            if workspaces[w].selectedSessionID == session.id {
                workspaces[w].selectedSessionID = neighborID
            }
        }
    }

    func closeSelected() {
        if let session = selectedSession {
            close(session)
        }
    }

    /// Disconnect the selected session's process but keep its tab (so it can be
    /// reconnected from the banner). No-ops if nothing is selected or running.
    func disconnectSelected() {
        selectedSession?.disconnect()
    }

    /// Disconnect every running SSH tunnel (leaves plain local shells untouched).
    func disconnectAllTunnels() {
        // Iterate a snapshot since close(_:) mutates `sessions`.
        for session in sessions.filter({ $0.kind == .ssh && $0.isRunning }) {
            close(session)
        }
    }

    /// Forcefully stop every session's underlying process — used on quit so no SSH
    /// tunnel can outlive the app and keep holding its forwarded ports (which would
    /// make the next launch's reconnect collide on them). Leaves `sessions` intact
    /// so the open-state has already been persisted by the caller.
    func shutDownAllProcesses() {
        for session in sessions { session.shutDown() }
    }

    func select(_ session: TerminalSession) {
        selectedSessionID = session.id
    }

    /// Mark a session as detached (shown in its own window) and move tab focus.
    func markDetached(_ session: TerminalSession) {
        detachedSessionIDs.insert(session.id)
        if let w = workspaces.firstIndex(where: { $0.tabIDs.contains(session.id) }),
           workspaces[w].selectedSessionID == session.id {
            let remaining = workspaces[w].tabIDs.filter { !detachedSessionIDs.contains($0) }
            workspaces[w].selectedSessionID = remaining.first
        }
    }

    /// Mark a session as re-attached to the main window's tab bar and focus it.
    /// It returns into the *current* workspace so it reappears where the user is.
    func markAttached(_ session: TerminalSession) {
        detachedSessionIDs.remove(session.id)
        for i in workspaces.indices { workspaces[i].tabIDs.removeAll { $0 == session.id } }
        if let i = currentIndex {
            workspaces[i].tabIDs.append(session.id)
            workspaces[i].selectedSessionID = session.id
        }
    }

    /// Re-apply a theme to every open session launched from the given profile.
    func applyTheme(_ theme: TerminalTheme, toProfileID id: UUID) {
        for session in sessions where session.profileID == id {
            session.applyTheme(theme)
        }
    }

    // MARK: - Terminal text size

    /// The terminal a menu-driven zoom should affect: whichever terminal currently
    /// has keyboard focus (a tiled tab or a detached window), else the selected
    /// main-window tab. (When a terminal itself has focus it also handles ⌘+/⌘−
    /// directly, before the menu.)
    var focusedTerminalSession: TerminalSession? {
        if let responder = NSApp.keyWindow?.firstResponder as? NSView,
           let session = sessions.first(where: { $0.terminalView === responder }) {
            return session
        }
        return selectedSession
    }

    func increaseFontSize() { focusedTerminalSession?.zoom(.increase) }
    func decreaseFontSize() { focusedTerminalSession?.zoom(.decrease) }
    func resetFontSize()    { focusedTerminalSession?.zoom(.reset) }

    // MARK: - Tab reordering

    /// Move an attached tab from one position to another within the current workspace.
    func moveAttachedSession(from fromIndex: Int, to toIndex: Int) {
        let attached = attachedSessions
        guard fromIndex != toIndex,
              attached.indices.contains(fromIndex),
              attached.indices.contains(toIndex),
              let i = currentIndex else { return }
        let movingID = attached[fromIndex].id
        let targetID = attached[toIndex].id
        guard let from = workspaces[i].tabIDs.firstIndex(of: movingID),
              let to = workspaces[i].tabIDs.firstIndex(of: targetID) else { return }
        workspaces[i].tabIDs.remove(at: from)
        workspaces[i].tabIDs.insert(movingID, at: to)
    }

    // MARK: - Saved-workspace library

    private let savedWorkspacesKey = "savedWorkspaces.v1"

    /// Save the current workspace's tab set under a name so it can be reopened later.
    func saveCurrentWorkspace(name: String) {
        guard let ws = currentWorkspace else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? ws.name : trimmed
        let tabs = snapshotTabs(for: ws)
        if let idx = savedWorkspaces.firstIndex(where: { $0.name == finalName }) {
            savedWorkspaces[idx].tabs = tabs
            savedWorkspaces[idx].isTiled = ws.isTiled
            savedWorkspaces[idx].tileLayout = ws.tileLayout
        } else {
            savedWorkspaces.append(SavedWorkspace(name: finalName, tabs: tabs,
                                                  isTiled: ws.isTiled,
                                                  tileLayout: ws.tileLayout))
        }
        persistSavedWorkspaces()
    }

    /// Open a saved workspace as a new top-level workspace tab.
    func openSavedWorkspace(_ saved: SavedWorkspace) {
        let ws = Workspace(name: saved.name,
                           isTiled: saved.isTiled,
                           tileLayout: saved.tileLayout ?? TileLayout())
        workspaces.append(ws)
        currentWorkspaceID = ws.id
        for tab in saved.tabs { recreate(tab) }
    }

    func deleteSavedWorkspace(_ id: UUID) {
        savedWorkspaces.removeAll { $0.id == id }
        persistSavedWorkspaces()
    }

    private func persistSavedWorkspaces() {
        if let data = try? JSONEncoder().encode(savedWorkspaces) {
            UserDefaults.standard.set(data, forKey: savedWorkspacesKey)
        }
    }

    private func loadSavedWorkspaces() {
        guard let data = UserDefaults.standard.data(forKey: savedWorkspacesKey),
              let saved = try? JSONDecoder().decode([SavedWorkspace].self, from: data) else { return }
        savedWorkspaces = saved
    }

    // MARK: - Session persistence ("resume last session")

    private let openStateKey = "openState.v2"
    private let legacyOpenSessionsKey = "openSessions.v1"
    private var persistCancellable: AnyCancellable?

    /// Snapshot one workspace's live tabs into codable form (skips dead sessions).
    private func snapshotTabs(for ws: Workspace) -> [SessionSnapshot] {
        ws.tabIDs.compactMap { id -> SessionSnapshot? in
            guard let s = sessions.first(where: { $0.id == id }) else { return nil }
            return SessionSnapshot(kind: s.kind, profileID: s.profileID,
                                   webURL: s.webModel?.currentURLString, title: s.title)
        }
    }

    /// Start saving the open workspaces whenever they change, so the next launch
    /// can resume them. Call once, *after* any initial restore.
    func beginPersistingOpenSessions() {
        guard persistCancellable == nil else { return }
        persistCancellable = Publishers
            .CombineLatest3($sessions, $workspaces, $currentWorkspaceID)
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.writeOpenState() }
    }

    /// Force-save the current open workspaces (used on app termination).
    func persistOpenSessions() { writeOpenState() }

    private func writeOpenState() {
        let snaps = workspaces.map { ws -> WorkspaceSnapshot in
            let liveTabIDs = ws.tabIDs.filter { id in sessions.contains { $0.id == id } }
            let selIndex = ws.selectedSessionID.flatMap { liveTabIDs.firstIndex(of: $0) }
            return WorkspaceSnapshot(name: ws.name, isTiled: ws.isTiled,
                                     tileLayout: ws.tileLayout,
                                     selectedIndex: selIndex, tabs: snapshotTabs(for: ws))
        }
        let current = workspaces.firstIndex { $0.id == currentWorkspaceID } ?? 0
        let state = OpenStateSnapshot(workspaces: snaps, currentIndex: current)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: openStateKey)
        }
    }

    /// The saved open-state, migrating a legacy flat session list if needed.
    private func savedOpenState() -> OpenStateSnapshot? {
        if let data = UserDefaults.standard.data(forKey: openStateKey),
           let state = try? JSONDecoder().decode(OpenStateSnapshot.self, from: data) {
            return state
        }
        if let data = UserDefaults.standard.data(forKey: legacyOpenSessionsKey),
           let tabs = try? JSONDecoder().decode([SessionSnapshot].self, from: data),
           !tabs.isEmpty {
            return OpenStateSnapshot(
                workspaces: [WorkspaceSnapshot(name: "Workspace 1", isTiled: false,
                                               selectedIndex: nil, tabs: tabs)],
                currentIndex: 0)
        }
        return nil
    }

    /// How many tabs were open when the app last quit (drives the resume button).
    var savedSessionCount: Int {
        savedOpenState()?.workspaces.reduce(0) { $0 + $1.tabs.count } ?? 0
    }

    /// Recreate one saved tab in the current workspace. Profiles that no longer
    /// exist are skipped; a saved blank browser tab reopens blank.
    private func recreate(_ snap: SessionSnapshot) {
        let store = ProfileStore.shared
        let profile = snap.profileID.flatMap { id in store.profiles.first { $0.id == id } }
        switch snap.kind {
        case .localShell:
            if let profile { connect(profile: profile) } else { openLocalShell() }
        case .ssh:
            if let profile { connect(profile: profile) }
        case .sftp:
            if let profile { connectSFTP(profile: profile) }
        case .vnc:
            if let profile { connectVNC(profile: profile) }
        case .web:
            if let s = snap.webURL, let url = URL(string: s) {
                var proxy: WebProxy? = nil
                if let profile, let sx = profile.socksProxy {
                    proxy = WebProxy(host: sx.host, port: sx.port)
                }
                openWeb(url: url, title: snap.title ?? (url.host ?? "Web"),
                        profileID: snap.profileID, proxy: proxy)
            } else {
                openBlankWeb()
            }
        }
    }

    /// Recreate the workspaces saved from a previous run. No-op if nothing saved.
    func restoreSavedSessions() {
        // Only restore into a clean slate. Re-running this while tabs are already
        // open would replace the `workspaces` array and leave the old sessions'
        // ssh processes running but unreferenced — invisible "zombie" tunnels that
        // keep holding their forwarded ports and break the next real connection.
        guard sessions.isEmpty else { return }
        guard let state = savedOpenState(), !state.workspaces.isEmpty else { return }
        let built = state.workspaces.map {
            Workspace(name: $0.name, isTiled: $0.isTiled,
                      tileLayout: $0.tileLayout ?? TileLayout())
        }
        workspaces = built
        for (i, snap) in state.workspaces.enumerated() {
            currentWorkspaceID = built[i].id
            for tab in snap.tabs { recreate(tab) }
            if let sel = snap.selectedIndex,
               let w = workspaces.firstIndex(where: { $0.id == built[i].id }),
               workspaces[w].tabIDs.indices.contains(sel) {
                workspaces[w].selectedSessionID = workspaces[w].tabIDs[sel]
            }
        }
        let current = min(max(0, state.currentIndex), workspaces.count - 1)
        if workspaces.indices.contains(current) {
            currentWorkspaceID = workspaces[current].id
        }
    }

    /// If the user enabled "resume last session", recreate the previous tabs.
    func restoreLastSessionIfEnabled() {
        // First reap any tunnels left over from a previous run that crashed or was
        // force-quit (so applicationWillTerminate never reaped them). They'd still
        // be holding their forwarded ports, and the tunnels we're about to restore
        // — or the user's next manual connect — would collide on those ports and
        // die. Safe to do here: we're past the single-instance check, so any match
        // is genuinely a leftover, not a second live copy of the app.
        reapStrayTunnels()
        if AppSettings.shared.resumeLastSession {
            restoreSavedSessions()
        }
    }

    /// Find and hang up `ssh` processes that look exactly like one of our own
    /// profile *tunnels* (our ssh binary, the profile's destination, and at least
    /// one `-L`/`-R`/`-D` forward) and are still alive from a previous run. We match
    /// on the profile destination so an unrelated ssh the user started by hand is
    /// never touched.
    private func reapStrayTunnels() {
        let profiles = ProfileStore.shared.profiles.filter { !$0.isLocal }
        guard !profiles.isEmpty else { return }
        let destinations: [String] = profiles.compactMap { p in
            let host = p.host.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { return nil }
            let user = p.username.trimmingCharacters(in: .whitespaces)
            return user.isEmpty ? host : "\(user)@\(host)"
        }
        guard !destinations.isEmpty else { return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        do { try task.run() } catch { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return }

        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let sp = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = pid_t(trimmed[..<sp]) else { continue }
            let cmd = String(trimmed[trimmed.index(after: sp)...])
            guard cmd.hasPrefix(SSHCommandBuilder.sshPath) else { continue }
            let hasForward = cmd.contains(" -L ") || cmd.contains(" -R ") || cmd.contains(" -D ")
            guard hasForward, destinations.contains(where: { cmd.contains($0) }) else { continue }
            kill(pid, SIGHUP)
        }
    }
}
