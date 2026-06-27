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

    /// When true, opening a tab won't reroute to its profile's assigned
    /// workspace. Set while *restoring* tabs into specific workspaces (resume /
    /// open-saved-workspace), so they land where they were saved.
    private var suppressWorkspaceRouting = false

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

    /// Look up a live session by id.
    func session(id: UUID) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    // MARK: - Docked side panes

    /// The current workspace's left drawer, with only its live, attached panes.
    var leftDock: DockColumn? { validColumn(currentWorkspace?.leftDock) }
    /// The current workspace's right drawer, with only its live, attached panes.
    var rightDock: DockColumn? { validColumn(currentWorkspace?.rightDock) }
    /// The current workspace's top drawer, with only its live, attached panes.
    var topDock: DockColumn? { validColumn(currentWorkspace?.topDock) }
    /// The current workspace's bottom drawer, with only its live, attached panes.
    var bottomDock: DockColumn? { validColumn(currentWorkspace?.bottomDock) }

    /// A column is only shown for panes whose session still exists and isn't
    /// detached; an empty column shows nothing.
    private func validColumn(_ column: DockColumn?) -> DockColumn? {
        guard var column else { return nil }
        column.panes = column.panes.filter { pane in
            sessions.contains(where: { $0.id == pane.sessionID })
                && !detachedSessionIDs.contains(pane.sessionID)
        }
        return column.panes.isEmpty ? nil : column
    }

    /// Session ids currently docked to any edge in the current workspace.
    private var dockedSessionIDs: Set<UUID> {
        var ids = Set<UUID>()
        for side in DockSide.allFour {
            (dock(side)?.panes ?? []).forEach { ids.insert($0.sessionID) }
        }
        return ids
    }

    /// The validated drawer for a given side in the current workspace.
    private func dock(_ side: DockSide) -> DockColumn? {
        switch side {
        case .left:   return leftDock
        case .right:  return rightDock
        case .top:    return topDock
        case .bottom: return bottomDock
        }
    }

    /// Attached sessions shown in the center tab bar / tile grid — i.e. everything
    /// not pulled out into a drawer.
    var centerSessions: [TerminalSession] {
        let docked = dockedSessionIDs
        return attachedSessions.filter { !docked.contains($0.id) }
    }

    /// Whether a session is currently pinned to a drawer.
    func isDocked(_ id: UUID) -> Bool { dockedSessionIDs.contains(id) }

    /// Which side a session is docked to, if any.
    func dockSide(of id: UUID) -> DockSide? {
        for side in DockSide.allFour
        where rawColumn(side)?.sessionIDs.contains(id) == true { return side }
        return nil
    }

    /// The stored (un-validated) drawer for a side in the current workspace.
    private func rawColumn(_ side: DockSide) -> DockColumn? {
        switch side {
        case .left:   return currentWorkspace?.leftDock
        case .right:  return currentWorkspace?.rightDock
        case .top:    return currentWorkspace?.topDock
        case .bottom: return currentWorkspace?.bottomDock
        }
    }

    /// Pull a tab out of the center area and add it to the end of `side`'s
    /// drawer, stacking with anything already docked there. Re-expands the drawer.
    func dock(_ session: TerminalSession, to side: DockSide) {
        guard let i = currentIndex else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            // Remove it from wherever it might already be docked, then append.
            removePane(session.id, inWorkspaceAt: i)
            var column = column(side, inWorkspaceAt: i) ?? DockColumn()
            column.panes.append(DockedPane(sessionID: session.id))
            column.collapsed = false
            setColumn(column, side: side, inWorkspaceAt: i)
            // If the docked tab was the selected one, move selection to a center tab.
            if workspaces[i].selectedSessionID == session.id {
                workspaces[i].selectedSessionID = centerSessions.first?.id
            }
        }
    }

    /// Return a docked tab to the normal tab bar / tile grid and select it.
    func undock(_ session: TerminalSession) { undock(sessionID: session.id) }

    func undock(sessionID id: UUID) {
        guard let i = currentIndex else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            removePane(id, inWorkspaceAt: i)
            workspaces[i].selectedSessionID = id
        }
    }

    /// Collapse / expand the whole drawer on a side (the slide-out rail).
    func toggleColumnCollapsed(_ side: DockSide) {
        guard let i = currentIndex else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            guard var c = column(side, inWorkspaceAt: i) else { return }
            c.collapsed.toggle()
            setColumn(c, side: side, inWorkspaceAt: i)
        }
    }

    /// Collapse / expand the drawer that contains a given session (used by menus
    /// that act on a specific tab).
    func toggleDockCollapsed(_ id: UUID) {
        guard let side = dockSide(of: id) else { return }
        toggleColumnCollapsed(side)
    }

    /// Set a drawer's cross-axis size as a fraction of the detail area (clamped):
    /// width for left/right, height for top/bottom.
    func setColumnWidth(_ side: DockSide, fraction: Double) {
        guard let i = currentIndex, var c = column(side, inWorkspaceAt: i) else { return }
        c.width = min(max(fraction, 0.08), 0.45)
        setColumn(c, side: side, inWorkspaceAt: i)
    }

    /// Set the relative sizes of the stacked panes in a side's drawer.
    func setColumnPaneWeights(_ side: DockSide, _ weights: [Double]) {
        guard let i = currentIndex, var c = column(side, inWorkspaceAt: i),
              c.panes.count == weights.count else { return }
        for k in c.panes.indices { c.panes[k].heightWeight = max(0.05, weights[k]) }
        setColumn(c, side: side, inWorkspaceAt: i)
    }

    /// Remove a session from whichever drawer holds it, dropping an empty column.
    private func removePane(_ id: UUID, inWorkspaceAt i: Int) {
        for side in DockSide.allFour {
            guard var c = column(side, inWorkspaceAt: i) else { continue }
            c.panes.removeAll { $0.sessionID == id }
            setColumn(c.panes.isEmpty ? nil : c, side: side, inWorkspaceAt: i)
        }
    }

    /// The stored drawer for a side in workspace `i`.
    private func column(_ side: DockSide, inWorkspaceAt i: Int) -> DockColumn? {
        switch side {
        case .left:   return workspaces[i].leftDock
        case .right:  return workspaces[i].rightDock
        case .top:    return workspaces[i].topDock
        case .bottom: return workspaces[i].bottomDock
        }
    }

    private func setColumn(_ column: DockColumn?, side: DockSide, inWorkspaceAt i: Int) {
        switch side {
        case .left:   workspaces[i].leftDock = column
        case .right:  workspaces[i].rightDock = column
        case .top:    workspaces[i].topDock = column
        case .bottom: workspaces[i].bottomDock = column
        }
    }

    /// Clear any dock entry that referenced `id` (used when a tab closes/detaches).
    private func clearDocks(for id: UUID, inWorkspaceAt i: Int) {
        removePane(id, inWorkspaceAt: i)
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
        // Honor the profile's “Open in workspace” assignment up front, so the tab
        // — whether newly opened or an existing one we reuse — ends up there.
        let assigned = routeToAssignedWorkspace(for: profile.id)
        if profile.isLocal { connectLocalProfile(profile); return }
        // A profile's tunnel binds fixed forwarded ports, so a second tunnel for
        // the same profile can't bind them (ssh runs with ExitOnForwardFailure=yes)
        // and dies the instant it connects with "Address already in use". So never
        // open a second tab for a profile: reuse the existing one. If it's running,
        // just reveal it; if it was disconnected, reconnect it in place.
        if let existing = sessions.first(where: {
            $0.profileID == profile.id && $0.kind == .ssh
        }) {
            // An assigned profile's tab follows its workspace on every connect.
            if assigned { adoptSessionIntoCurrentWorkspace(existing) }
            reveal(existing)
            if !existing.isRunning {
                reapStrayTunnel(for: profile)   // free ports a slow SIGHUP hasn't yet
                existing.restart()
            }
            return
        }
        // No tab for this profile yet. A tunnel left over from a closed tab /
        // workspace (or a previous run) could still be holding this profile's
        // forwarded ports; reap it first so the fresh launch doesn't collide. If
        // we actually killed one, give the OS a moment to release the ports.
        if reapStrayTunnel(for: profile) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.spawnTunnel(for: profile)
            }
        } else {
            spawnTunnel(for: profile)
        }
    }

    /// Build and start a profile's ssh tunnel tab. Re-checks for an existing tab
    /// first, since the user may have connected again during a reap delay.
    private func spawnTunnel(for profile: SSHProfile) {
        if let existing = sessions.first(where: {
            $0.profileID == profile.id && $0.kind == .ssh
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
        routeToAssignedWorkspace(for: profile.id)
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

    /// One-click "set up passwordless login": copy this profile's SSH **public
    /// key** to the server with `ssh-copy-id`, so future connections sign in with
    /// the key instead of a password. Runs in a local terminal tab so host-key /
    /// password prompts work normally (and a saved Keychain password autofills).
    ///
    /// If the profile has no key yet, offers to generate a new ed25519 key or
    /// choose an existing public key. When a key is published for a profile that
    /// had no identity file, the profile adopts it so the next connection uses it.
    func setUpKeyLogin(profile: SSHProfile) {
        guard !profile.isLocal else { return }
        guard !profile.host.trimmingCharacters(in: .whitespaces).isEmpty else {
            warn(title: "Add a host first",
                 text: "This profile needs a host before a key can be copied to it.")
            return
        }

        if let pub = SSHCopyIDBuilder.publicKey(for: profile) {
            launchKeyInstall(profile: profile, publicKey: pub, generate: false)
            return
        }

        // No usable public key found — offer to generate one or pick an existing.
        let alert = NSAlert()
        alert.messageText = "Set up passwordless login"
        alert.informativeText = """
        No SSH key was found for “\(profile.name)”. Generate a new ed25519 key and \
        copy it to \(profile.subtitle), or choose an existing public key to publish.
        """
        alert.addButton(withTitle: "Generate New Key")
        alert.addButton(withTitle: "Choose Existing…")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            launchKeyInstall(profile: profile,
                             publicKey: SSHCopyIDBuilder.defaultGeneratedPublicKey(),
                             generate: true)
        case .alertSecondButtonReturn:
            if let pub = chooseExistingPublicKey() {
                launchKeyInstall(profile: profile, publicKey: pub, generate: false)
            }
        default:
            break
        }
    }

    /// Open a local terminal tab that runs the key-setup script for the profile.
    private func launchKeyInstall(profile: SSHProfile, publicKey: String, generate: Bool) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script = SSHCopyIDBuilder.setupScript(for: profile, publicKey: publicKey,
                                                  generateKey: generate)
        let session = TerminalSession(
            kind: .localShell,
            title: "\(profile.name) — Key Setup",
            executable: shell,
            args: ["-c", script],
            commandPreview: SSHCopyIDBuilder.commandPreview(for: profile, publicKey: publicKey),
            profileID: profile.id,
            theme: TerminalTheme.theme(id: profile.theme),
            fontSize: profile.fontSize,
            autofillPassword: KeychainStore.shared.hasPassword(for: profile.id),
            requireAuthForPassword: profile.requireAuthForSavedPassword
        )
        addAndStart(session)

        // If this profile had no explicit key, adopt the one we just published so
        // future connections authenticate with it. Only persist for a profile that
        // actually exists in the store (skip an unsaved one from the editor).
        if profile.identityFile.trimmingCharacters(in: .whitespaces).isEmpty,
           ProfileStore.shared.profiles.contains(where: { $0.id == profile.id }) {
            var updated = profile
            updated.identityFile = SSHCopyIDBuilder.privateKeyPath(forPublicKey: publicKey)
            ProfileStore.shared.update(updated)
        }
    }

    /// Prompt the user to choose an existing public key (`*.pub`) in `~/.ssh`.
    private func chooseExistingPublicKey() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose SSH Public Key"
        panel.message = "Choose the public key (.pub) to copy to the server."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: SSHCopyIDBuilder.sshDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    /// Ad-hoc "set up passwordless login" that isn't tied to a saved profile —
    /// for when you're in a plain local terminal and just want to push your SSH
    /// key to some server. Prompts for the destination (and port), then runs the
    /// same `ssh-copy-id` flow against a throwaway profile (nothing is saved).
    func setUpKeyLoginPrompt(prefillDestination: String = "") {
        let alert = NSAlert()
        alert.messageText = "Set Up Passwordless Login"
        alert.informativeText = "Copy your SSH key to a server so you can sign in without a password. You’ll be asked for the account password once."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 320
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 52))

        let destField = NSTextField(frame: NSRect(x: 0, y: 26, width: width, height: 24))
        destField.stringValue = prefillDestination
        destField.placeholderString = "user@server.example.com"
        container.addSubview(destField)

        let portLabel = NSTextField(labelWithString: "Port")
        portLabel.frame = NSRect(x: 0, y: 2, width: 34, height: 20)
        container.addSubview(portLabel)

        let portField = NSTextField(frame: NSRect(x: 38, y: 0, width: 64, height: 24))
        portField.stringValue = "22"
        portField.alignment = .center
        container.addSubview(portField)

        alert.accessoryView = container
        alert.window.initialFirstResponder = destField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let raw = destField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        var username = ""
        var host = raw
        if let at = raw.firstIndex(of: "@") {
            username = String(raw[..<at]).trimmingCharacters(in: .whitespaces)
            host = String(raw[raw.index(after: at)...]).trimmingCharacters(in: .whitespaces)
        }
        guard !host.isEmpty else {
            warn(title: "Enter a server",
                 text: "Type the server to connect to, like deploy@server.example.com.")
            return
        }
        var profile = SSHProfile()
        profile.name = host
        profile.host = host
        profile.username = username
        let port = portField.stringValue.trimmingCharacters(in: .whitespaces)
        profile.port = port.isEmpty ? "22" : port
        setUpKeyLogin(profile: profile)
    }

    /// Show a simple warning alert.
    private func warn(title: String, text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Open a new tab that tunnels VNC over SSH (a local port-forward to the
    /// server's screen) and launches macOS Screen Sharing through it.
    func connectVNC(profile: SSHProfile) {
        routeToAssignedWorkspace(for: profile.id)
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

    /// If a profile is assigned to a named workspace (the editor's “Open in
    /// workspace” field), make that workspace current — switching to the open one
    /// of that name, or creating it if none is open. Returns whether the profile
    /// has an assignment, so callers can also pull an existing tab into it.
    /// No-op (returns false) for ad-hoc tabs, unassigned profiles, or while
    /// restoring saved tabs. Only the profile's primary tabs (connect / SFTP /
    /// VNC) call this; utility tabs (key setup, links, services) stay put.
    @discardableResult
    private func routeToAssignedWorkspace(for profileID: UUID?) -> Bool {
        guard !suppressWorkspaceRouting, let profileID,
              let profile = ProfileStore.shared.profiles.first(where: { $0.id == profileID })
        else { return false }
        let name = profile.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        // Already in the right workspace — assignment satisfied, nothing to switch.
        if currentWorkspace?.name == name { return true }
        if let existing = workspaces.first(where: { $0.name == name }) {
            currentWorkspaceID = existing.id
        } else {
            let tiled = UserDefaults.standard.bool(forKey: "tileTerminals")
            let ws = Workspace(name: name, isTiled: tiled)
            workspaces.append(ws)
            currentWorkspaceID = ws.id
        }
        return true
    }

    /// Move a session into the current workspace if it lives elsewhere, then
    /// select it. Lets an assigned profile's existing tab follow its workspace
    /// assignment on reconnect, instead of staying where it was first opened.
    private func adoptSessionIntoCurrentWorkspace(_ session: TerminalSession) {
        guard let target = currentIndex else { return }
        if workspaces[target].tabIDs.contains(session.id) {
            workspaces[target].selectedSessionID = session.id
            return
        }
        for i in workspaces.indices where workspaces[i].tabIDs.contains(session.id) {
            workspaces[i].tabIDs.removeAll { $0 == session.id }
            if workspaces[i].selectedSessionID == session.id {
                workspaces[i].selectedSessionID = workspaces[i].tabIDs.last
            }
        }
        workspaces[target].tabIDs.append(session.id)
        workspaces[target].selectedSessionID = session.id
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

    /// Open a local file-browser (“Finder”) tab. Drag files from it onto a
    /// terminal to paste their paths, or onto an SFTP tab to upload them.
    func openFinder(path: String? = nil) {
        let start = path ?? FileManager.default.homeDirectoryForCurrentUser.path
        let folderName = URL(fileURLWithPath: start).lastPathComponent
        let session = TerminalSession(
            kind: .finder,
            title: folderName.isEmpty ? "Files" : folderName,
            executable: "",
            args: [],
            commandPreview: start,
            startDirectory: start
        )
        addAndStart(session)
    }

    /// Open an **ad-hoc** MQTT / Redis tab that connects directly to `host:port`
    /// (no SSH tunnel / profile). Used by the “new connection” setup sheet.
    func openAdHocService(category: ForwardCategory, host: String, port: Int,
                          username: String, password: String) {
        guard let kind = category.terminalKind, port > 0 else { return }
        let cleanHost = host.trimmingCharacters(in: .whitespaces).isEmpty
            ? "127.0.0.1" : host.trimmingCharacters(in: .whitespaces)
        let session = TerminalSession(
            kind: kind,
            title: "\(category.title) — \(cleanHost):\(port)",
            executable: "",
            args: [],
            commandPreview: "\(category.title) \(cleanHost):\(port)",
            servicePort: port,
            serviceHost: cleanHost,
            serviceUsername: username.trimmingCharacters(in: .whitespaces),
            servicePassword: password
        )
        addAndStart(session)
    }

    /// Open the tab a categorized forward describes — a **Web Page**, **MQTT**, or
    /// **Redis** tab — pointed at the forward's local port. Brings the profile's
    /// SSH tunnel up first (so the port is listening), pausing briefly for `ssh`
    /// to bind the forward when it had to start fresh.
    func openService(_ category: ForwardCategory, forward: PortForward, profile: SSHProfile) {
        guard category.isLaunchable, let endpoint = forward.localEndpoint else { return }
        let wasRunning = isTunnelRunning(profile)
        ensureConnected(profile)
        let launch: () -> Void = { [weak self] in
            self?.launchService(category, forward: forward, endpoint: endpoint, profile: profile)
        }
        if wasRunning || profile.isLocal {
            launch()
        } else {
            // Give the freshly-launched tunnel a moment to open the local listener.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: launch)
        }
    }

    /// Whether this profile's SSH tunnel tab is already up.
    private func isTunnelRunning(_ profile: SSHProfile) -> Bool {
        sessions.contains { $0.profileID == profile.id && $0.kind == .ssh && $0.isRunning }
    }

    private func launchService(_ category: ForwardCategory,
                               forward: PortForward,
                               endpoint: (host: String, port: Int),
                               profile: SSHProfile) {
        switch category {
        case .webpage:
            guard let url = URL(string: "http://\(endpoint.host):\(endpoint.port)") else { return }
            openWeb(url: url, title: "\(profile.name) — Web", profileID: profile.id)
        case .mqtt, .redis:
            let username = forward.serviceUsername.trimmingCharacters(in: .whitespaces)
            // The service password (if any) lives in the Keychain keyed by the
            // forward's id. Fetch it (gated by the profile's Touch ID setting),
            // then open the native client tab. If the user cancels auth, don't
            // open a doomed tab.
            if KeychainStore.shared.hasPassword(for: forward.id) {
                KeychainStore.shared.password(
                    for: forward.id,
                    requireAuth: profile.requireAuthForSavedPassword,
                    reason: "Use the saved \(category.title) password for “\(profile.name)”"
                ) { [weak self] result in
                    guard case .success(let password) = result else { return }
                    DispatchQueue.main.async {
                        self?.spawnServiceTab(category, endpoint: endpoint, profile: profile,
                                              username: username, password: password)
                    }
                }
            } else {
                spawnServiceTab(category, endpoint: endpoint, profile: profile,
                                username: username, password: "")
            }
        case .none:
            break
        }
    }

    /// Create a native MQTT / Redis client tab that connects to the forwarded
    /// local port. No external CLI is involved — the client speaks the protocol
    /// directly, so nothing extra needs to be installed.
    private func spawnServiceTab(_ category: ForwardCategory,
                                 endpoint: (host: String, port: Int), profile: SSHProfile,
                                 username: String, password: String) {
        guard let kind = category.terminalKind else { return }
        let session = TerminalSession(
            kind: kind,
            title: "\(profile.name) — \(category.title)",
            executable: "",
            args: [],
            commandPreview: "\(category.title) \(endpoint.host):\(endpoint.port)",
            profileID: profile.id,
            theme: TerminalTheme.theme(id: profile.theme),
            fontSize: profile.fontSize,
            servicePort: endpoint.port,
            serviceHost: endpoint.host,
            serviceUsername: username,
            servicePassword: password
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
        // Pick the neighbouring *center* tab (next, else previous) within its
        // workspace so selection lands on a visible tab after the close (docked
        // and detached tabs aren't selection candidates).
        let wsIndex = workspaces.firstIndex { $0.tabIDs.contains(session.id) }
        var neighborID: UUID?
        if let w = wsIndex {
            var docked = Set<UUID>()
            (workspaces[w].leftDock?.panes ?? []).forEach { docked.insert($0.sessionID) }
            (workspaces[w].rightDock?.panes ?? []).forEach { docked.insert($0.sessionID) }
            let centerIDs = workspaces[w].tabIDs.filter {
                !detachedSessionIDs.contains($0) && !docked.contains($0)
            }
            if let pos = centerIDs.firstIndex(of: session.id) {
                neighborID = centerIDs[(pos + 1)...].first ?? centerIDs[..<pos].last
            } else {
                neighborID = centerIDs.last
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
            clearDocks(for: session.id, inWorkspaceAt: w)
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
        if let w = workspaces.firstIndex(where: { $0.tabIDs.contains(session.id) }) {
            // A detached tab can't also be a side drawer.
            clearDocks(for: session.id, inWorkspaceAt: w)
            if workspaces[w].selectedSessionID == session.id {
                let remaining = workspaces[w].tabIDs.filter { !detachedSessionIDs.contains($0) }
                workspaces[w].selectedSessionID = remaining.first
            }
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

    /// Move a center tab from one position to another within the current workspace.
    func moveCenterTab(from fromIndex: Int, to toIndex: Int) {
        let center = centerSessions
        guard fromIndex != toIndex,
              center.indices.contains(fromIndex),
              center.indices.contains(toIndex),
              let i = currentIndex else { return }
        let movingID = center[fromIndex].id
        let targetID = center[toIndex].id
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
        let docks = dockSnapshots(for: ws)
        if let idx = savedWorkspaces.firstIndex(where: { $0.name == finalName }) {
            savedWorkspaces[idx].tabs = tabs
            savedWorkspaces[idx].isTiled = ws.isTiled
            savedWorkspaces[idx].tileLayout = ws.tileLayout
            savedWorkspaces[idx].docks = docks
        } else {
            savedWorkspaces.append(SavedWorkspace(name: finalName, tabs: tabs,
                                                  isTiled: ws.isTiled,
                                                  tileLayout: ws.tileLayout,
                                                  docks: docks))
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
        suppressWorkspaceRouting = true
        defer { suppressWorkspaceRouting = false }
        for tab in saved.tabs { recreate(tab) }
        if let w = workspaces.firstIndex(where: { $0.id == ws.id }) {
            applyDockSnapshots(saved.docks, toWorkspaceAt: w)
        }
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
                                   webURL: s.webModel?.currentURLString ?? s.finderModel?.currentPath,
                                   title: s.title,
                                   servicePort: s.servicePort)
        }
    }

    /// Snapshot a workspace's side drawers by tab index (matching `snapshotTabs`
    /// order), so they can be re-paired with the recreated tabs on the next launch.
    private func dockSnapshots(for ws: Workspace) -> [DockSnapshot]? {
        let liveTabIDs = ws.tabIDs.filter { id in sessions.contains { $0.id == id } }
        func snapshot(_ column: DockColumn?, _ side: DockSide) -> DockSnapshot? {
            guard let column else { return nil }
            let panes = column.panes.compactMap { pane -> DockPaneSnapshot? in
                guard let idx = liveTabIDs.firstIndex(of: pane.sessionID) else { return nil }
                return DockPaneSnapshot(tabIndex: idx, heightWeight: pane.heightWeight)
            }
            guard !panes.isEmpty else { return nil }
            return DockSnapshot(side: side, width: column.width,
                                collapsed: column.collapsed, panes: panes)
        }
        let result = [snapshot(ws.leftDock, .left), snapshot(ws.rightDock, .right),
                      snapshot(ws.topDock, .top), snapshot(ws.bottomDock, .bottom)]
            .compactMap { $0 }
        return result.isEmpty ? nil : result
    }

    /// Re-pair saved side drawers with the recreated tabs of a workspace.
    private func applyDockSnapshots(_ docks: [DockSnapshot]?, toWorkspaceAt w: Int) {
        guard let docks, workspaces.indices.contains(w) else { return }
        let tabIDs = workspaces[w].tabIDs
        for d in docks {
            let panes = d.panes.compactMap { ps -> DockedPane? in
                guard tabIDs.indices.contains(ps.tabIndex) else { return nil }
                return DockedPane(sessionID: tabIDs[ps.tabIndex], heightWeight: ps.heightWeight)
            }
            guard !panes.isEmpty else { continue }
            let column = DockColumn(width: d.width, collapsed: d.collapsed, panes: panes)
            switch d.side {
            case .left:   workspaces[w].leftDock = column
            case .right:  workspaces[w].rightDock = column
            case .top:    workspaces[w].topDock = column
            case .bottom: workspaces[w].bottomDock = column
            }
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
                                     selectedIndex: selIndex, tabs: snapshotTabs(for: ws),
                                     docks: dockSnapshots(for: ws))
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
        case .mqtt, .redis:
            if let profile, let port = snap.servicePort,
               let fwd = profile.forwards.first(where: { $0.localEndpoint?.port == port }) {
                openService(snap.kind == .redis ? .redis : .mqtt, forward: fwd, profile: profile)
            }
        case .finder:
            openFinder(path: snap.webURL)
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
        suppressWorkspaceRouting = true
        defer { suppressWorkspaceRouting = false }
        for (i, snap) in state.workspaces.enumerated() {
            currentWorkspaceID = built[i].id
            for tab in snap.tabs { recreate(tab) }
            if let w = workspaces.firstIndex(where: { $0.id == built[i].id }) {
                if let sel = snap.selectedIndex,
                   workspaces[w].tabIDs.indices.contains(sel) {
                    workspaces[w].selectedSessionID = workspaces[w].tabIDs[sel]
                }
                applyDockSnapshots(snap.docks, toWorkspaceAt: w)
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

        for (pid, cmd) in runningSSHProcesses() {
            let hasForward = cmd.contains(" -L ") || cmd.contains(" -R ") || cmd.contains(" -D ")
            guard hasForward, destinations.contains(where: { cmd.contains($0) }) else { continue }
            kill(pid, SIGHUP)
        }
    }

    /// Free one profile's forwarded ports from any leftover `ssh` tunnel of ours
    /// (a tab/workspace that was closed, or a previous run) so a fresh connect
    /// doesn't collide with "Address already in use". Matches only our ssh
    /// processes for this profile's destination that carry a forward, and never
    /// touches a tunnel we still track in `sessions` (so another profile's live
    /// tunnel — or this one — is safe). Returns true if it killed anything.
    @discardableResult
    private func reapStrayTunnel(for profile: SSHProfile) -> Bool {
        let host = profile.host.trimmingCharacters(in: .whitespaces)
        guard !profile.isLocal, !host.isEmpty else { return false }
        let user = profile.username.trimmingCharacters(in: .whitespaces)
        let destination = user.isEmpty ? host : "\(user)@\(host)"

        // PIDs of ssh tunnels we still track in-app — never reap these.
        let livePIDs = Set(sessions.compactMap { s -> pid_t? in
            s.kind == .ssh ? s.terminalView.process?.shellPid : nil
        }.filter { $0 > 0 })

        var killed = false
        for (pid, cmd) in runningSSHProcesses() {
            guard cmd.contains(destination), !livePIDs.contains(pid) else { continue }
            let hasForward = cmd.contains(" -L ") || cmd.contains(" -R ") || cmd.contains(" -D ")
            guard hasForward else { continue }
            kill(pid, SIGHUP)
            killed = true
        }
        return killed
    }

    /// A snapshot of running processes launched from our `ssh` binary, as
    /// `(pid, command)` pairs. Shared by the stray-tunnel reapers.
    private func runningSSHProcesses() -> [(pid: pid_t, command: String)] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return [] }

        var result: [(pid: pid_t, command: String)] = []
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let sp = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = pid_t(trimmed[..<sp]) else { continue }
            let cmd = String(trimmed[trimmed.index(after: sp)...])
            guard cmd.hasPrefix(SSHCommandBuilder.sshPath) else { continue }
            result.append((pid, cmd))
        }
        return result
    }
}
