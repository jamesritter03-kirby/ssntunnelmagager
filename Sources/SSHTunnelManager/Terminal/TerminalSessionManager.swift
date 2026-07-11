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
    /// Tabs / workspaces the user recently closed without saving, newest first,
    /// shown on the welcome screen so an accidental close can be undone.
    @Published private(set) var recentlyClosed: [ClosedItem] = []

    static let shared = TerminalSessionManager()

    /// When on, keystrokes typed in one terminal are mirrored to every other live
    /// terminal (multi-server "type once, run everywhere").
    @Published var broadcastInput = false

    /// Per-session auto-reconnect backoff bookkeeping.
    private var reconnectAttempts: [UUID: Int] = [:]
    private var reconnectWorkItems: [UUID: DispatchWorkItem] = [:]
    /// Drives the periodic tunnel-health probe.
    private var healthTimer: Timer?

    private init() {
        let tiled = UserDefaults.standard.bool(forKey: "tileTerminals")
        let first = Workspace(name: "Workspace 1", isTiled: tiled)
        workspaces = [first]
        currentWorkspaceID = first.id
        loadSavedWorkspaces()
        loadRecentlyClosed()
        observeRunningState()
        startHealthMonitoring()
    }

    /// Forwards each open session's `isRunning` changes to this manager's own
    /// `objectWillChange`, so views that show per-profile connection state — the
    /// sidebar's status dots — refresh live when a tunnel comes up or drops. The
    /// `sessions` array itself doesn't change when a child process merely stops,
    /// so without this relay those observers would go stale.
    private var runningStateCancellables: [AnyCancellable] = []
    private var stateRelayCancellable: AnyCancellable?

    private func observeRunningState() {
        stateRelayCancellable = $sessions
            .sink { [weak self] list in
                guard let self else { return }
                // Wire broadcast-input relay on every ssh / local shell tab.
                for session in list { self.wireBroadcast(for: session) }
                self.runningStateCancellables = list.map { session in
                    session.$isRunning
                        .dropFirst()
                        .receive(on: RunLoop.main)
                        .sink { [weak self] running in
                            self?.handleRunningChange(session, isRunning: running)
                        }
                }
            }
    }

    /// Mirror one terminal's keystrokes to every other live terminal when
    /// broadcast-input is enabled.
    private func wireBroadcast(for session: TerminalSession) {
        guard session.kind == .ssh || session.kind == .localShell else { return }
        session.onUserTypedForBroadcast = { [weak self, weak session] data in
            guard let self, let session, self.broadcastInput else { return }
            let bytes = Array(data)
            for other in self.sessions where other.id != session.id {
                other.injectBroadcast(bytes)
            }
        }
    }

    /// React to a session starting/stopping: refresh dependent views, reset (or
    /// schedule) auto-reconnect, and clear stale health.
    private func handleRunningChange(_ session: TerminalSession, isRunning: Bool) {
        objectWillChange.send()
        if isRunning {
            reconnectAttempts[session.id] = 0
            reconnectWorkItems[session.id]?.cancel()
            reconnectWorkItems[session.id] = nil
            return
        }
        session.tunnelHealth = .unknown
        // A dropped connection: auto-reconnect if the profile opted in and the
        // user didn't stop it on purpose.
        guard !session.userInitiatedStop,
              session.kind == .ssh,
              let pid = session.profileID,
              let profile = ProfileStore.shared.profiles.first(where: { $0.id == pid }),
              profile.autoReconnect else { return }
        scheduleAutoReconnect(session, profile: profile)
    }

    /// Schedule an auto-reconnect for a dropped session using exponential backoff
    /// (2, 4, 8, 16 s, capped at 30 s).
    private func scheduleAutoReconnect(_ session: TerminalSession, profile: SSHProfile) {
        let attempt = (reconnectAttempts[session.id] ?? 0) + 1
        reconnectAttempts[session.id] = attempt
        let delay = min(30.0, pow(2.0, Double(min(attempt, 5))))
        reconnectWorkItems[session.id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            // Bail if the tab was closed, reconnected, or stopped in the meantime.
            guard self.sessions.contains(where: { $0.id == session.id }),
                  !session.isRunning, !session.userInitiatedStop else { return }
            self.reapStrayTunnel(for: profile)
            session.restart()
        }
        reconnectWorkItems[session.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Tunnel health

    /// Start the periodic probe that checks each running tunnel's forwarded local
    /// ports are actually listening (drives the sidebar health dot).
    private func startHealthMonitoring() {
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.probeTunnelHealth()
        }
        timer.tolerance = 1.0
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func probeTunnelHealth() {
        for session in sessions where session.kind == .ssh && session.isRunning {
            guard let pid = session.profileID,
                  let profile = ProfileStore.shared.profiles.first(where: { $0.id == pid }) else { continue }
            let endpoints = profile.localForwardEndpoints
            guard !endpoints.isEmpty else { continue }
            TCPProbe.allReachable(endpoints, timeout: 2.0) { healthy in
                let newHealth: TunnelHealth = healthy ? .healthy : .degraded
                if session.tunnelHealth != newHealth { session.tunnelHealth = newHealth }
            }
        }
    }

    /// The live tunnel health for a profile (its running ssh tab), or `.unknown`.
    func tunnelHealth(for profile: SSHProfile) -> TunnelHealth {
        sessions.first { $0.profileID == profile.id && $0.kind == .ssh && $0.isRunning }?
            .tunnelHealth ?? .unknown
    }

    // MARK: - Auto-connect on launch

    /// Connect every profile flagged **auto-connect on launch**. Called once at
    /// startup (after any resume-last-session restore).
    func autoConnectProfilesOnLaunch() {
        let toConnect = ProfileStore.shared.profiles.filter { $0.autoConnectOnLaunch }
        guard !toConnect.isEmpty else { return }
        // Stagger slightly so several tunnels don't all spawn on the same runloop
        // turn (and so each lands after the window/workspace is ready).
        for (index, profile) in toConnect.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(index) * 0.2) { [weak self] in
                self?.connect(profile: profile)
            }
        }
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
        // Remember the whole workspace (its tabs + drawers) so it can be reopened
        // from the welcome screen if the close was accidental.
        recordClosedWorkspace(workspaces[i])
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
        // Honor the profile's workspace assignment up front: switch to (or build)
        // its dedicated workspace — recreating an assigned launch template the
        // first time — so the connection tab lands there.
        let assigned = ensureDedicatedWorkspace(for: profile.id, instantiateTemplate: true)
        // A workspace-launcher profile has no connection of its own — building (or
        // revealing) its dedicated workspace from the template is the whole action.
        if profile.isWorkspaceLauncher && assigned { return }
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
        // Use mosh when the profile asks for it and a mosh client is installed;
        // otherwise fall back to plain ssh. (mosh doesn't do port forwards.)
        let useMosh = profile.useMosh && MoshCommandBuilder.isAvailable
        // A ControlMaster socket for plain-ssh tunnels enables live add/remove of
        // port forwards (ssh -O forward). mosh sessions don't get one.
        let controlPath = useMosh ? nil : TerminalSessionManager.controlSocketPath(for: profile.id)
        let session = TerminalSession(
            kind: .ssh,
            title: profile.name,
            executable: useMosh ? MoshCommandBuilder.executablePath : SSHCommandBuilder.sshPath,
            args: useMosh ? MoshCommandBuilder.arguments(for: profile)
                          : SSHCommandBuilder.arguments(for: profile, controlPath: controlPath),
            commandPreview: useMosh ? MoshCommandBuilder.commandPreview(for: profile)
                                    : SSHCommandBuilder.commandPreview(for: profile),
            profileID: profile.id,
            theme: TerminalTheme.theme(id: profile.theme),
            fontSize: profile.fontSize,
            autofillPassword: KeychainStore.shared.hasPassword(for: profile.id),
            requireAuthForPassword: profile.requireAuthForSavedPassword,
            runOnConnectCommand: profile.runOnConnect,
            logSession: profile.logSession,
            controlSocketPath: controlPath
        )
        addAndStart(session)
    }

    /// A short, unique ControlMaster socket path for a profile's tunnel. Kept in
    /// `/tmp` so the path stays well under the ~104-char unix-socket limit.
    static func controlSocketPath(for profileID: UUID) -> String {
        "/tmp/sshtm-\(profileID.uuidString.prefix(8)).sock"
    }

    // MARK: - Live port forwarding (ControlMaster)

    /// Whether live add/remove of forwards is available for a session (a running,
    /// profile-backed ssh tunnel with a control socket).
    func liveForwardSupported(_ session: TerminalSession) -> Bool {
        session.kind == .ssh && session.isRunning && session.controlSocketPath != nil
    }

    /// Add a port forward to a live tunnel via `ssh -O forward`, optionally saving
    /// it to the profile so it comes back on the next connect.
    func addLiveForward(_ forward: PortForward, to session: TerminalSession, persist: Bool) {
        runControlForward("forward", forward, on: session)
        guard persist, let pid = session.profileID,
              var profile = ProfileStore.shared.profiles.first(where: { $0.id == pid }) else { return }
        profile.forwards.append(forward)
        ProfileStore.shared.update(profile)
    }

    /// Cancel a forward on a live tunnel via `ssh -O cancel`, optionally removing
    /// it from the profile too.
    func cancelLiveForward(_ forward: PortForward, on session: TerminalSession, persist: Bool) {
        runControlForward("cancel", forward, on: session)
        guard persist, let pid = session.profileID,
              var profile = ProfileStore.shared.profiles.first(where: { $0.id == pid }) else { return }
        profile.forwards.removeAll { $0.id == forward.id }
        ProfileStore.shared.update(profile)
    }

    /// Run `ssh -S <socket> -O <op> <flag> <spec> <dest>` to add or cancel a
    /// forward on the running master, off the main thread.
    private func runControlForward(_ op: String, _ forward: PortForward, on session: TerminalSession) {
        guard let socket = session.controlSocketPath,
              let pid = session.profileID,
              let profile = ProfileStore.shared.profiles.first(where: { $0.id == pid }),
              let option = SSHCommandBuilder.forwardOption(forward) else { return }
        let dest = SSHCommandBuilder.destination(for: profile)
        guard !dest.isEmpty else { return }
        let args = ["-S", socket, "-O", op, option.flag, option.spec, dest]
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: SSHCommandBuilder.sshPath)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
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
            startDirectory: dir,
            runOnConnectCommand: profile.runOnConnect,
            logSession: profile.logSession
        )
        addAndStart(session)
    }

    /// Open a new tab running an interactive `sftp` file-transfer session for the
    /// profile (same host / auth as a normal connection).
    func connectSFTP(profile: SSHProfile) {
        routeToAssignedWorkspace(for: profile.id)
        addAndStart(makeSFTPSession(for: profile))
    }

    /// Build (but don't start) an interactive `sftp` session tab for a profile.
    private func makeSFTPSession(for profile: SSHProfile) -> TerminalSession {
        let args = SFTPCommandBuilder.arguments(for: profile)
        return TerminalSession(
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
    }

    /// Reveal an existing SFTP tab for `profile`, or open a new one (reconnecting
    /// a disconnected one). Used by the VNC tab's **File Transfer** menu so using
    /// it repeatedly focuses the same browser instead of stacking duplicate tabs.
    @discardableResult
    func revealOrOpenSFTP(profile: SSHProfile) -> TerminalSession {
        routeToAssignedWorkspace(for: profile.id)
        if let existing = sessions.first(where: {
            $0.profileID == profile.id && $0.kind == .sftp
        }) {
            reveal(existing)
            if !existing.isRunning { existing.restart() }
            return existing
        }
        let session = makeSFTPSession(for: profile)
        addAndStart(session)
        return session
    }

    /// Open (or reveal) an SFTP tab for `profile` and upload `urls` once it's
    /// connected — the "Upload Files…" action on a VNC tab's File Transfer menu.
    /// The tab is left open afterwards for further browsing / transfers.
    func uploadViaSFTP(profile: SSHProfile, urls: [URL]) {
        guard !urls.isEmpty else { return }
        let session = revealOrOpenSFTP(profile: profile)
        guard let client = session.sftpClient else { return }
        whenSFTPReady(client) { client.upload(urls) }
    }

    /// Run `action` once an SFTP client reaches a connected state, polling briefly.
    /// Gives up if the connection fails/ends or after ~10s (the tab stays open so
    /// the user can still transfer manually).
    private func whenSFTPReady(_ client: SFTPClient, remainingAttempts: Int = 40,
                               _ action: @escaping () -> Void) {
        if client.isConnected { action(); return }
        switch client.phase {
        case .failed, .ended: return
        default: break
        }
        guard remainingAttempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.whenSFTPReady(client, remainingAttempts: remainingAttempts - 1, action)
        }
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

    /// Bring a session's tab to the front (public wrapper over `reveal`).
    func focusSession(_ session: TerminalSession) { reveal(session) }

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

    /// Open a copy of a tab in the **current** workspace. Content tabs (web,
    /// files, editor, spreadsheet, shells) reopen mirroring their live state;
    /// connection tabs reconnect a fresh independent session. A profile-backed
    /// ssh tab can't be duplicated (its tunnel binds fixed ports) and is filtered
    /// out by `TerminalSession.canDuplicate`.
    func duplicate(_ session: TerminalSession) {
        guard session.canDuplicate else { return }
        // Keep the copy here rather than routing a profile tab to its dedicated
        // workspace.
        suppressWorkspaceRouting = true
        defer { suppressWorkspaceRouting = false }

        let profile = session.profileID.flatMap { id in
            ProfileStore.shared.profiles.first { $0.id == id }
        }

        switch session.kind {
        case .web:
            let urlString = session.webModel?.currentURLString ?? ""
            if let url = URL(string: urlString), !urlString.isEmpty {
                var proxy: WebProxy? = nil
                if let profile, let sx = profile.socksProxy {
                    proxy = WebProxy(host: sx.host, port: sx.port)
                }
                openWeb(url: url, title: session.title, profileID: session.profileID, proxy: proxy)
            } else {
                openBlankWeb()
            }
        case .finder:
            openFinder(path: session.finderModel?.currentPath)
        case .editor:
            openTextEditor(path: session.textEditorModel?.fileURL?.path)
        case .spreadsheet:
            openSpreadsheet(path: session.spreadsheetModel?.fileURL?.path)
        case .localShell:
            let copy = TerminalSession(
                kind: .localShell,
                title: session.title,
                executable: session.executable,
                args: session.args,
                commandPreview: session.commandPreview,
                profileID: session.profileID,
                theme: session.theme,
                fontSize: session.fontSize,
                startDirectory: session.startDirectory
            )
            addAndStart(copy)
        case .ssh:
            // Only ad-hoc ssh reaches here (canDuplicate filters profile tunnels).
            openAdHocSSH(host: session.serviceHost, port: session.servicePort ?? 22,
                         username: session.serviceUsername,
                         password: session.presetPassword ?? "")
        case .sftp:
            if let profile {
                connectSFTP(profile: profile)
            } else {
                openAdHocSFTP(host: session.serviceHost, port: session.servicePort ?? 22,
                              username: session.serviceUsername,
                              password: session.presetPassword ?? "")
            }
        case .vnc:
            if let profile {
                connectVNC(profile: profile)
            } else {
                openAdHocVNC(host: session.serviceHost, port: session.servicePort ?? 5900,
                             username: session.serviceUsername, password: session.servicePassword)
            }
        case .mqtt, .redis:
            let category: ForwardCategory = session.kind == .redis ? .redis : .mqtt
            if let profile, let port = session.servicePort,
               let fwd = profile.forwards.first(where: { $0.localEndpoint?.port == port }) {
                openService(category, forward: fwd, profile: profile)
            } else if let port = session.servicePort {
                openAdHocService(category: category, host: session.serviceHost, port: port,
                                 username: session.serviceUsername, password: session.servicePassword)
            }
        }
    }

    /// Light routing for a profile's secondary tabs (SFTP / VNC): make the
    /// profile's dedicated workspace current, creating an empty one if needed, but
    /// **without** building its launch template — a full `connect` does that.
    /// Returns whether the profile launches into a dedicated workspace. No-op
    /// (returns false) for ad-hoc tabs, unassigned profiles, or while restoring.
    @discardableResult
    private func routeToAssignedWorkspace(for profileID: UUID?) -> Bool {
        ensureDedicatedWorkspace(for: profileID, instantiateTemplate: false)
    }

    /// Make the profile's **dedicated workspace** current — reusing the one
    /// already open for this profile, adopting a matching one restored from a
    /// previous run, or creating a fresh workspace named after the profile. When
    /// `instantiateTemplate` is true and the profile has an assigned **saved
    /// workspace** template, that template's tabs and layout are recreated the
    /// first time the workspace is built (the profile's own primary connection is
    /// left for the caller to start, so it isn't opened twice).
    ///
    /// Returns whether the profile launches into a dedicated workspace. No-op
    /// (returns false) for ad-hoc tabs, unassigned profiles, or while restoring
    /// saved tabs (`suppressWorkspaceRouting`).
    @discardableResult
    private func ensureDedicatedWorkspace(for profileID: UUID?, instantiateTemplate: Bool) -> Bool {
        guard !suppressWorkspaceRouting, let profileID,
              let profile = ProfileStore.shared.profiles.first(where: { $0.id == profileID }),
              profile.launchesInDedicatedWorkspace
        else { return false }

        let name = profile.dedicatedWorkspaceName
        let template = profile.workspaceTemplateID.flatMap { tid in
            savedWorkspaces.first { $0.id == tid }
        }

        // Reuse the workspace already dedicated to this profile; otherwise adopt a
        // matching one restored from a previous run (matched by name). A restored
        // workspace that already holds tabs is treated as fully built so we don't
        // duplicate them.
        let index: Int
        if let i = workspaces.firstIndex(where: { $0.sourceProfileID == profileID }) {
            index = i
        } else if let i = workspaces.firstIndex(where: {
            $0.sourceProfileID == nil && $0.name == name
        }) {
            workspaces[i].sourceProfileID = profileID
            if !workspaces[i].tabIDs.isEmpty { workspaces[i].templateInstantiated = true }
            index = i
        } else {
            let tiled = template?.isTiled ?? UserDefaults.standard.bool(forKey: "tileTerminals")
            var ws = Workspace(name: name, isTiled: tiled,
                               tileLayout: template?.tileLayout ?? TileLayout())
            ws.sourceProfileID = profileID
            workspaces.append(ws)
            index = workspaces.count - 1
        }
        // Tint the pill from the profile's chosen color (if any) so a
        // profile-launched workspace always shows its designated color.
        if let c = profile.workspaceTabColor {
            workspaces[index].tabColor = c
        }
        currentWorkspaceID = workspaces[index].id

        // Build the template once, on the first full launch of this workspace.
        if instantiateTemplate, let template, !workspaces[index].templateInstantiated {
            workspaces[index].templateInstantiated = true
            recreateTemplate(template, forProfile: profileID, intoWorkspaceAt: index)
        }
        return true
    }

    /// Recreate a saved workspace's tabs and drawers into an existing workspace as
    /// the profile's launch template. The profile's **own** primary connection
    /// (its ssh / local‑shell tab) is skipped — the caller starts exactly one of
    /// those — and dock indices are remapped to the rebuilt tab order.
    ///
    /// A template is built from *some* profile's workspace; that profile's tabs
    /// carry its id and name. When a **different** profile launches the template
    /// (most often after duplicating a profile, which inherits its template),
    /// those tabs are re‑pointed at the launching profile so they connect as — and
    /// are named after — the profile you're actually launching.
    private func recreateTemplate(_ template: SavedWorkspace,
                                  forProfile profileID: UUID,
                                  intoWorkspaceAt index: Int) {
        // Recreation calls back into connect*/openService, which would otherwise
        // try to re-route each tab into its own workspace; suppress that so every
        // template tab lands here, in order.
        suppressWorkspaceRouting = true
        defer { suppressWorkspaceRouting = false }

        // The template's "main" connection profile — the one it was built around
        // (its first ssh / local‑shell tab, else its first profile tab). Its tabs
        // are the ones re‑pointed at the launching profile below.
        let originProfileID =
            template.tabs.first(where: {
                ($0.kind == .ssh || $0.kind == .localShell) && $0.profileID != nil
            })?.profileID
            ?? template.tabs.first(where: { $0.profileID != nil })?.profileID

        // A workspace launcher (“Save as Profile”) rebuilds the workspace exactly:
        // every tab keeps its original profile and reconnects as itself, and the
        // launcher opens no connection of its own — so skip the duplicate-profile
        // re-pointing entirely.
        let launchingProfile = ProfileStore.shared.profiles.first(where: { $0.id == profileID })
        let isLauncher = launchingProfile?.isWorkspaceLauncher ?? false

        // The launching device profile's own address. Ad-hoc (profile-less)
        // connection tabs in a *shared* saved workspace are re-pointed at this so
        // every device profile that reuses the same “edge” workspace opens its
        // service / web tabs on its **own** box — not the IP baked into the template
        // when it was first saved (the “profile shows .34 but the tab connects to
        // .33” bug). Done per-launch, in memory; the shared template is never
        // mutated, so one workspace can safely back many device profiles at once.
        let launchingHost: String? = {
            guard let p = launchingProfile, !p.isLocal else { return nil }
            let h = p.host.trimmingCharacters(in: .whitespaces)
            return h.isEmpty ? nil : h
        }()
        // The device the template was built around: a web tab that pointed at that
        // box follows the launching profile, while an external/cloud URL is left
        // alone.
        let originHost: String? = {
            if let oid = originProfileID,
               let p = ProfileStore.shared.profiles.first(where: { $0.id == oid }) {
                let h = p.host.trimmingCharacters(in: .whitespaces).lowercased()
                if !h.isEmpty { return h }
            }
            if let h = template.tabs.first(where: {
                $0.profileID == nil && ($0.kind == .ssh || $0.kind == .sftp)
                    && !($0.serviceHost ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            })?.serviceHost {
                return h.trimmingCharacters(in: .whitespaces).lowercased()
            }
            return nil
        }()

        var keptTemplateIndices: [Int] = []
        for (i, tab) in template.tabs.enumerated() {
            var tab = tab
            if isLauncher {
                // A launcher rebuilds its saved workspace as-is. But a launcher
                // that carries its **own host** — a per-device workspace profile
                // (e.g. many devices sharing one "edge" layout, each on its own IP)
                // — re-points the layout's ad-hoc tabs at that host, so the device
                // opens the shared workspace on its own box instead of the address
                // baked into the template. A hostless multi-profile launcher has
                // `launchingHost == nil`, so it keeps every tab exactly as saved.
                if tab.profileID == nil, let host = launchingHost {
                    tab = repointingAdHocTab(tab, to: host, originHost: originHost)
                }
                keptTemplateIndices.append(i)
                recreate(tab, owningProfileID: profileID)
                continue
            }
            let isMainProfileTab = tab.profileID == profileID
                || (originProfileID != nil && tab.profileID == originProfileID)
            // The launching profile's own primary tab is started by the caller
            // (with the single-tunnel de-dupe); building it here too would open a
            // second one (local shells especially aren't de-duped).
            if isMainProfileTab && (tab.kind == .ssh || tab.kind == .localShell) {
                continue
            }
            // Re‑point the origin profile's other tabs (SFTP / VNC / service / web)
            // at the launching profile so a duplicated or reused template connects
            // as this profile and shows its name, not the one it was saved from.
            if let origin = originProfileID, origin != profileID, tab.profileID == origin {
                tab.profileID = profileID
                tab.title = nil     // let the launching profile's name drive the title
            }
            // Re-point ad-hoc (profile-less) connection tabs at the launching device
            // so a shared workspace opens each profile's services on its own host
            // instead of the address baked into the template.
            if tab.profileID == nil, let host = launchingHost {
                tab = repointingAdHocTab(tab, to: host, originHost: originHost)
            }
            keptTemplateIndices.append(i)
            recreate(tab, owningProfileID: profileID)
        }

        // Remap the template's dock panes (indexed into its full tab list) onto the
        // rebuilt order, dropping any that referenced the skipped primary tab.
        let remap = Dictionary(uniqueKeysWithValues:
            keptTemplateIndices.enumerated().map { ($1, $0) })
        let docks = template.docks?.compactMap { dock -> DockSnapshot? in
            let panes = dock.panes.compactMap { pane -> DockPaneSnapshot? in
                remap[pane.tabIndex].map { DockPaneSnapshot(tabIndex: $0, heightWeight: pane.heightWeight) }
            }
            guard !panes.isEmpty else { return nil }
            return DockSnapshot(side: dock.side, width: dock.width,
                                collapsed: dock.collapsed, panes: panes)
        }
        applyDockSnapshots(docks, toWorkspaceAt: index)
    }

    /// A copy of an ad-hoc (profile-less) template tab re-addressed to `host`, so a
    /// shared saved workspace opens each launching device profile's tabs on its own
    /// box. Service tabs (ssh / sftp / vnc / mqtt / redis) always follow the
    /// launching host; a **web** tab follows only when it pointed at the template's
    /// origin device (`originHost`) so an external/cloud dashboard is left as-is.
    /// Tabs with no stored host are returned unchanged.
    private func repointingAdHocTab(_ tab: SessionSnapshot, to host: String,
                                    originHost: String?) -> SessionSnapshot {
        var t = tab
        switch t.kind {
        case .ssh, .sftp, .vnc, .mqtt, .redis:
            let current = (t.serviceHost ?? "").trimmingCharacters(in: .whitespaces)
            if !current.isEmpty, current.lowercased() != host.lowercased() {
                t.serviceHost = host
            }
        case .web:
            if let s = t.webURL,
               let h = TerminalSessionManager.urlHost(of: s)?.lowercased(),
               let origin = originHost, h == origin,
               let swapped = TerminalSessionManager.replacingHost(in: s, with: host) {
                t.webURL = swapped
            }
        default:
            break
        }
        return t
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

    /// Open a Notepad++‑style text‑editor tab. Pass a file path to open it, or
    /// nil for a new blank document.
    func openTextEditor(path: String? = nil, backupID: UUID? = nil) {
        let title: String
        if let path, !path.isEmpty {
            let name = URL(fileURLWithPath: path).lastPathComponent
            title = name.isEmpty ? "Untitled" : name
        } else {
            title = "Untitled"
        }
        let session = TerminalSession(
            kind: .editor,
            title: title,
            executable: "",
            args: [],
            commandPreview: path ?? "",
            startDirectory: path,
            editorBackupID: backupID
        )
        addAndStart(session)
    }

    /// Open a **remote file for editing**: it has already been downloaded to
    /// `localURL`; this opens it in a text‑editor tab and wires a save‑back link
    /// so each save uploads it to `remotePath` over the given SFTP `uploader`.
    /// Backs the SFTP browser's right‑click **Edit** action.
    func openRemoteEdit(localURL: URL, remoteName: String, remotePath: String,
                        uploader: RemoteFileUploader, serverLabel: String) {
        let session = TerminalSession(
            kind: .editor,
            title: remoteName,
            executable: "",
            args: [],
            commandPreview: remotePath,
            startDirectory: localURL.path
        )
        session.textEditorModel?.beginRemoteEdit(
            uploader: uploader, localURL: localURL,
            remoteName: remoteName, remotePath: remotePath, serverLabel: serverLabel)
        addAndStart(session)
    }

    /// Open a spreadsheet tab. Pass a CSV / TSV file path to open it, or nil for
    /// a new blank grid.
    func openSpreadsheet(path: String? = nil) {
        let title: String
        if let path, !path.isEmpty {
            let name = URL(fileURLWithPath: path).lastPathComponent
            title = name.isEmpty ? "Untitled" : name
        } else {
            title = "Untitled"
        }
        let session = TerminalSession(
            kind: .spreadsheet,
            title: title,
            executable: "",
            args: [],
            commandPreview: path ?? "",
            startDirectory: path
        )
        addAndStart(session)
    }

    /// Open a **remote delimited file as a spreadsheet**: it has already been
    /// downloaded to `localURL`; this opens it in a spreadsheet tab and wires a
    /// save‑back link so each save uploads it to `remotePath` over the given
    /// SFTP `uploader`. Backs the SFTP browser's “Open as Spreadsheet” action.
    func openRemoteSpreadsheet(localURL: URL, remoteName: String, remotePath: String,
                               uploader: RemoteFileUploader, serverLabel: String) {
        let session = TerminalSession(
            kind: .spreadsheet,
            title: remoteName,
            executable: "",
            args: [],
            commandPreview: remotePath,
            startDirectory: localURL.path
        )
        session.spreadsheetModel?.beginRemoteEdit(
            uploader: uploader, localURL: localURL,
            remoteName: remoteName, remotePath: remotePath, serverLabel: serverLabel)
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

    /// Open an **ad-hoc** VNC tab that points the built-in viewer **directly** at
    /// `host:port` (no SSH tunnel / profile). Used by the “New VNC Connection”
    /// setup sheet. For a tunneled, encrypted session, open VNC from a profile.
    func openAdHocVNC(host: String, port: Int, username: String, password: String,
                      scaling: Bool = true, viewOnly: Bool = false,
                      colorDepth: EmbeddedVNCViewer.ColorDepthOption = .trueColor) {
        guard port > 0 else { return }
        let cleanHost = host.trimmingCharacters(in: .whitespaces).isEmpty
            ? "127.0.0.1" : host.trimmingCharacters(in: .whitespaces)
        let session = TerminalSession(
            kind: .vnc,
            title: "VNC — \(cleanHost):\(port)",
            executable: "",
            args: [],
            commandPreview: "vnc://\(cleanHost):\(port)",
            servicePort: port,
            serviceHost: cleanHost,
            serviceUsername: username.trimmingCharacters(in: .whitespaces),
            servicePassword: password,
            vncScaling: scaling,
            vncViewOnly: viewOnly,
            vncColorDepth: colorDepth
        )
        addAndStart(session)
    }

    /// Build a throwaway `SSHProfile` (a fresh id, **not** saved to the store)
    /// from a host / port / username so the existing SSH and SFTP command
    /// builders can construct an ad-hoc, profile-free connection.
    private func adHocProfile(host: String, port: Int, username: String) -> SSHProfile {
        var profile = SSHProfile()
        let cleanHost = host.trimmingCharacters(in: .whitespaces)
        let cleanUser = username.trimmingCharacters(in: .whitespaces)
        profile.host = cleanHost
        profile.port = String(port)
        profile.username = cleanUser
        profile.name = cleanUser.isEmpty ? cleanHost : "\(cleanUser)@\(cleanHost)"
        return profile
    }

    /// Open an **ad-hoc** remote terminal (SSH) tab to `host:port` without a saved
    /// profile. A typed password (optional — key auth is tried first) is sent at
    /// the prompt but never stored. Used by the “New Remote Terminal” setup sheet.
    func openAdHocSSH(host: String, port: Int, username: String, password: String,
                      autofillSourceProfileID: UUID? = nil, autofillSourceRequireAuth: Bool = true) {
        let cleanHost = host.trimmingCharacters(in: .whitespaces)
        guard !cleanHost.isEmpty, port > 0 else { return }
        let profile = adHocProfile(host: cleanHost, port: port, username: username)
        let session = TerminalSession(
            kind: .ssh,
            title: profile.name,
            executable: SSHCommandBuilder.sshPath,
            args: SSHCommandBuilder.arguments(for: profile),
            commandPreview: SSHCommandBuilder.commandPreview(for: profile),
            autofillSourceProfileID: autofillSourceProfileID,
            autofillSourceRequireAuth: autofillSourceRequireAuth,
            servicePort: port,
            serviceHost: cleanHost,
            serviceUsername: username.trimmingCharacters(in: .whitespaces),
            presetPassword: password.isEmpty ? nil : password
        )
        addAndStart(session)
    }

    /// Open an **ad-hoc** SFTP file-transfer tab to `host:port` without a saved
    /// profile. A typed password (optional) is sent at the prompt but never
    /// stored. Used by the “New SFTP Connection” setup sheet.
    func openAdHocSFTP(host: String, port: Int, username: String, password: String,
                       credentialID: UUID? = nil,
                       autofillSourceProfileID: UUID? = nil, autofillSourceRequireAuth: Bool = true) {
        let cleanHost = host.trimmingCharacters(in: .whitespaces)
        guard !cleanHost.isEmpty, port > 0 else { return }
        let profile = adHocProfile(host: cleanHost, port: port, username: username)
        let session = TerminalSession(
            kind: .sftp,
            title: "\(profile.name) — SFTP",
            executable: SFTPCommandBuilder.sftpPath,
            args: SFTPCommandBuilder.arguments(for: profile),
            commandPreview: SFTPCommandBuilder.commandPreview(for: profile),
            autofillSourceProfileID: autofillSourceProfileID,
            autofillSourceRequireAuth: autofillSourceRequireAuth,
            servicePort: port,
            serviceHost: cleanHost,
            serviceUsername: username.trimmingCharacters(in: .whitespaces),
            presetPassword: password.isEmpty ? nil : password,
            sftpMountCredentialID: credentialID
        )
        addAndStart(session)
    }

    /// Re‑point a live **service** tab (`.mqtt` / `.redis`, direct `.vnc`, or
    /// `.sftp`) at new connection details and reconnect it **in place** — the new
    /// tab takes the old one's slot and selection. Because a session's connection
    /// details (and its native client) are immutable, we rebuild the tab rather
    /// than mutate it. Backs the right‑click **Edit Connection…** action.
    func reconnectSession(_ id: UUID, host: String, port: Int,
                          username: String, password: String) {
        guard let old = sessions.first(where: { $0.id == id }), port > 0 else { return }
        let cleanHost = host.trimmingCharacters(in: .whitespaces).isEmpty
            ? "127.0.0.1" : host.trimmingCharacters(in: .whitespaces)
        let cleanUser = username.trimmingCharacters(in: .whitespaces)

        let new: TerminalSession
        switch old.kind {
        case .mqtt, .redis:
            let category: ForwardCategory = old.kind == .redis ? .redis : .mqtt
            // If this tab is backed by a profile forward, persist the typed
            // password to that forward (Keychain, keyed by the forward id) and
            // keep the tab tied to its profile. This is what stops the endless
            // "Edit Connection → retype the password" loop: on the next launch the
            // workspace rebuilds this tab from the profile and reads the now-saved
            // password, so the user doesn't have to enter it again. A blank
            // password clears any saved one.
            let backingProfile = old.profileID.flatMap { pid in
                ProfileStore.shared.profiles.first { $0.id == pid }
            }
            let backingForward = backingProfile?.forwards.first {
                $0.localEndpoint?.port == old.servicePort
            }
            if let forward = backingForward {
                if password.isEmpty {
                    KeychainStore.shared.deletePassword(for: forward.id)
                } else {
                    KeychainStore.shared.setPassword(password, for: forward.id)
                }
            } else {
                // Ad-hoc service tab (no profile forward) launched from a saved
                // workspace — e.g. a shared “edge” layout opened by many device
                // profiles. Persist the typed password into that workspace's tab so
                // every future launch reconnects without re-entering it.
                persistAdHocServicePassword(for: old, password: password)
            }
            let serviceTitle: String = {
                if let forward = backingForward, !forward.trimmedName.isEmpty {
                    return forward.trimmedName
                }
                if let p = backingProfile { return "\(p.name) — \(category.title)" }
                return "\(category.title) — \(cleanHost):\(port)"
            }()
            new = TerminalSession(
                kind: old.kind,
                title: serviceTitle,
                executable: "",
                args: [],
                commandPreview: "\(category.title) \(cleanHost):\(port)",
                profileID: old.profileID,
                theme: backingProfile.map { TerminalTheme.theme(id: $0.theme) } ?? .default,
                fontSize: backingProfile?.fontSize ?? TerminalFontMetrics.default,
                servicePort: port,
                serviceHost: cleanHost,
                serviceUsername: cleanUser,
                servicePassword: password
            )
        case .vnc:
            // Only a direct (non‑tunnelled) VNC tab is re‑pointable here; a
            // profile's tunnelled VNC gets its endpoint from the profile.
            guard old.vncClient == nil else { return }
            let viewer = old.embeddedVNCViewer
            new = TerminalSession(
                kind: .vnc,
                title: "VNC — \(cleanHost):\(port)",
                executable: "",
                args: [],
                commandPreview: "vnc://\(cleanHost):\(port)",
                servicePort: port,
                serviceHost: cleanHost,
                serviceUsername: cleanUser,
                servicePassword: password,
                vncScaling: viewer?.isScalingEnabled ?? true,
                vncViewOnly: viewer?.isViewOnly ?? false,
                vncColorDepth: viewer?.colorDepth ?? .trueColor
            )
        case .sftp:
            // Clone the backing profile (so identity files / proxy‑jump survive)
            // and override host/port/user; fall back to a throwaway profile for an
            // ad‑hoc tab.
            var profile: SSHProfile
            if let pid = old.profileID,
               let p = ProfileStore.shared.profiles.first(where: { $0.id == pid }) {
                profile = p
            } else {
                profile = adHocProfile(host: cleanHost, port: port, username: cleanUser)
            }
            profile.host = cleanHost
            profile.port = String(port)
            profile.username = cleanUser
            let label = cleanUser.isEmpty ? cleanHost : "\(cleanUser)@\(cleanHost)"
            new = TerminalSession(
                kind: .sftp,
                title: "\(label) — SFTP",
                executable: SFTPCommandBuilder.sftpPath,
                args: SFTPCommandBuilder.arguments(for: profile),
                commandPreview: SFTPCommandBuilder.commandPreview(for: profile),
                servicePort: port,
                serviceHost: cleanHost,
                serviceUsername: cleanUser,
                presetPassword: password.isEmpty ? nil : password
            )
        default:
            return
        }
        replaceSession(old, with: new)
    }

    /// Swap `new` into `old`'s exact place (sessions order, workspace tab slot and
    /// selection), tear `old` down, and start `new`. Used by `reconnectSession`.
    private func replaceSession(_ old: TerminalSession, with new: TerminalSession) {
        let wasDetached = detachedSessionIDs.contains(old.id)
        // Put the replacement immediately after the old tab in the flat list…
        if let si = sessions.firstIndex(where: { $0.id == old.id }) {
            sessions.insert(new, at: si + 1)
        } else {
            sessions.append(new)
        }
        // …and in the same workspace slot, taking over selection.
        if let w = workspaces.firstIndex(where: { $0.tabIDs.contains(old.id) }) {
            if let ti = workspaces[w].tabIDs.firstIndex(of: old.id) {
                workspaces[w].tabIDs.insert(new.id, at: ti + 1)
            } else {
                workspaces[w].tabIDs.append(new.id)
            }
            if !wasDetached { workspaces[w].selectedSessionID = new.id }
        } else if let i = currentIndex {
            workspaces[i].tabIDs.append(new.id)
            workspaces[i].selectedSessionID = new.id
        }
        // Tear down and remove the old tab (no closed‑tab record — it's replaced,
        // not closed).
        old.shutDown()
        if let w = workspaces.firstIndex(where: { $0.tabIDs.contains(old.id) }) {
            clearDocks(for: old.id, inWorkspaceAt: w)
            workspaces[w].tabIDs.removeAll { $0 == old.id }
        }
        detachedSessionIDs.remove(old.id)
        sessions.removeAll { $0.id == old.id }
        // Start once the view has mounted at a real size.
        DispatchQueue.main.async { new.start() }
    }

    /// Locate the saved-workspace tab an **ad-hoc** service tab was launched from,
    /// so its password can be stored (and read again next launch). Resolves the
    /// live tab → its workspace → the launching profile → that profile's template,
    /// then matches the tab by kind + forwarded port (the host may have been
    /// re-pointed to this device, so it isn't a reliable key). Returns nil for a
    /// tab that isn't backed by a saved workspace (nothing to persist into).
    private func savedWorkspaceTabLocation(for old: TerminalSession) -> (ws: Int, tab: Int)? {
        guard let wi = workspaces.firstIndex(where: { $0.tabIDs.contains(old.id) }),
              let pid = workspaces[wi].sourceProfileID,
              let profile = ProfileStore.shared.profiles.first(where: { $0.id == pid }),
              let tid = profile.workspaceTemplateID,
              let ti = savedWorkspaces.firstIndex(where: { $0.id == tid }),
              let tabIdx = savedWorkspaces[ti].tabs.firstIndex(where: {
                  $0.profileID == nil && $0.kind == old.kind
                      && $0.servicePort == old.servicePort
              })
        else { return nil }
        return (ti, tabIdx)
    }

    /// Save (or clear) the password typed into an ad-hoc service tab's **Edit
    /// Connection** back onto the saved workspace tab it came from, keyed by a
    /// per-tab Keychain credential. A shared workspace stores it once, so every
    /// device profile that reuses the layout reconnects automatically — ending the
    /// “edit connection and retype the password” loop for profile-free service tabs.
    private func persistAdHocServicePassword(for old: TerminalSession, password: String) {
        guard let loc = savedWorkspaceTabLocation(for: old) else { return }
        let existing = savedWorkspaces[loc.ws].tabs[loc.tab].credentialID
        if password.isEmpty {
            if let cid = existing { KeychainStore.shared.deletePassword(for: cid) }
            savedWorkspaces[loc.ws].tabs[loc.tab].credentialID = nil
        } else {
            let cid = existing ?? UUID()
            if KeychainStore.shared.setPassword(password, for: cid) {
                savedWorkspaces[loc.ws].tabs[loc.tab].credentialID = cid
            }
        }
        persistSavedWorkspaces()
    }

    /// Whether reconnecting the given MQTT / Redis tab will **remember** its
    /// password for the next launch — either it's backed by a profile forward, or
    /// it's an ad-hoc tab launched from a saved workspace we can store the
    /// credential on. Drives the Edit Connection sheet's hint text.
    func serviceTabRemembersPassword(_ id: UUID) -> Bool {
        guard let s = sessions.first(where: { $0.id == id }),
              s.kind == .mqtt || s.kind == .redis else { return false }
        if let pid = s.profileID,
           let p = ProfileStore.shared.profiles.first(where: { $0.id == pid }),
           p.forwards.contains(where: { $0.localEndpoint?.port == s.servicePort }) {
            return true
        }
        return savedWorkspaceTabLocation(for: s) != nil
    }

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
            let title = forward.trimmedName.isEmpty ? "\(profile.name) — Web" : forward.trimmedName
            openWeb(url: url, title: title, profileID: profile.id)
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
                                              forward: forward,
                                              username: username, password: password)
                    }
                }
            } else {
                spawnServiceTab(category, endpoint: endpoint, profile: profile,
                                forward: forward,
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
                                 forward: PortForward,
                                 username: String, password: String) {
        guard let kind = category.terminalKind else { return }
        let title = forward.trimmedName.isEmpty
            ? "\(profile.name) — \(category.title)"
            : forward.trimmedName
        let session = TerminalSession(
            kind: kind,
            title: title,
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
        // A text editor with unsaved changes gets a Save / Don’t Save / Cancel
        // prompt; “Cancel” aborts the close and keeps the tab.
        if session.kind == .editor, let editor = session.textEditorModel,
           !editor.confirmCloseIfNeeded() {
            return
        }
        // Likewise for a spreadsheet tab with unsaved edits.
        if session.kind == .spreadsheet, let sheet = session.spreadsheetModel,
           !sheet.confirmCloseIfNeeded() {
            return
        }
        // Remember this tab so it can be reopened from the welcome screen if the
        // close was accidental (skips tabs we couldn't recreate, e.g. profile-free
        // tabs whose profile is gone).
        recordClosedTab(session)
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

    /// Disconnect a profile's primary connection tab — its SSH tunnel, or the
    /// login shell for a local profile — **without** removing the tab, so it shows
    /// the Reconnect banner and can be brought back with `connect(profile:)`. The
    /// mirror of the sidebar's Connect command. No-op if it isn't connected.
    func disconnect(profile: SSHProfile) {
        // A workspace launcher owns no connection of its own — it rebuilt a
        // dedicated workspace of independent tabs. “Disconnect” stops every running
        // tab in that workspace.
        if profile.isWorkspaceLauncher {
            for s in launcherWorkspaceSessions(for: profile) where s.isRunning {
                s.disconnect()
            }
            return
        }
        let kind: TerminalSession.Kind = profile.isLocal ? .localShell : .ssh
        sessions.first { $0.profileID == profile.id && $0.kind == kind }?.disconnect()
    }

    /// The live sessions belonging to a workspace-launcher's dedicated workspace
    /// (matched by `sourceProfileID`). Empty until the launcher has been connected
    /// at least once (which builds the workspace).
    private func launcherWorkspaceSessions(for profile: SSHProfile) -> [TerminalSession] {
        guard let ws = workspaces.first(where: { $0.sourceProfileID == profile.id }) else {
            return []
        }
        return ws.tabIDs.compactMap { tid in sessions.first(where: { $0.id == tid }) }
    }

    /// Whether `profile` has a running primary connection tab that Disconnect could
    /// act on. Read when the sidebar context menu opens to enable/disable it.
    func isConnected(profile: SSHProfile) -> Bool {
        // A workspace launcher opens no connection of its own — it rebuilds a
        // dedicated workspace whose tabs each reconnect under their own profile.
        // It counts as connected when that workspace has any running tab.
        if profile.isWorkspaceLauncher {
            return launcherWorkspaceSessions(for: profile).contains { $0.isRunning }
        }
        let kind: TerminalSession.Kind = profile.isLocal ? .localShell : .ssh
        return sessions.contains {
            $0.profileID == profile.id && $0.kind == kind && $0.isRunning
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

    func increaseFontSize() {
        if let editor = selectedEditorModel { editor.increaseFont(); return }
        focusedTerminalSession?.zoom(.increase)
    }
    func decreaseFontSize() {
        if let editor = selectedEditorModel { editor.decreaseFont(); return }
        focusedTerminalSession?.zoom(.decrease)
    }
    func resetFontSize() {
        if let editor = selectedEditorModel { editor.resetFont(); return }
        focusedTerminalSession?.zoom(.reset)
    }

    /// The text‑editor model of the selected tab, if the selection is an editor.
    private var selectedEditorModel: TextEditorModel? {
        guard let s = selectedSession, s.kind == .editor else { return nil }
        return s.textEditorModel
    }

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

    /// Move a workspace pill from one position to another (drag-reorder in the
    /// workspace bar). Matched by id so it's robust to the source and target
    /// having shifted. Order is display-only and persists with the open state, so
    /// the next launch restores the rearranged order.
    func moveWorkspace(fromID: UUID, toID: UUID) {
        guard fromID != toID,
              let from = workspaces.firstIndex(where: { $0.id == fromID }),
              let to = workspaces.firstIndex(where: { $0.id == toID }) else { return }
        let moving = workspaces.remove(at: from)
        workspaces.insert(moving, at: to)
    }

    /// Set (or clear, with `nil`) the pill tint of a workspace. Persisted with the
    /// open state so it survives relaunch.
    func setWorkspaceColor(_ color: TabColor?, forWorkspace id: UUID) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[i].tabColor = color
    }

    /// The profile that owns the workspace a session lives in, if that workspace
    /// was launched from a profile (its `sourceProfileID`). Lets tabs inside a
    /// profile-launched workspace surface that profile's snippets and links even
    /// when the tab itself is profile-free — e.g. an ad-hoc connection that was
    /// saved into a workspace template and rebuilt by a “Save as Profile” launcher.
    func owningProfile(forSession sessionID: UUID) -> SSHProfile? {
        guard let ws = workspaces.first(where: { $0.tabIDs.contains(sessionID) }),
              let pid = ws.sourceProfileID else { return nil }
        return ProfileStore.shared.profiles.first { $0.id == pid }
    }

    /// Set (or clear, with `nil`) the chip tint of a tab. Persisted per tab.
    func setTabColor(_ color: TabColor?, forSession id: UUID) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        s.tabColor = color
        // The session's own `objectWillChange` refreshes its chip live. Changing a
        // member object's property doesn't republish the `sessions` array, though,
        // so save the open state directly to persist the new tint across relaunch.
        writeOpenState()
    }

    private let savedWorkspacesKey = "savedWorkspaces.v1"

    /// Save the current workspace's tab set under a name so it can be reopened later.
    func saveCurrentWorkspace(name: String) {
        guard let ws = currentWorkspace else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? ws.name : trimmed
        upsertSavedWorkspace(from: ws, name: finalName)
    }

    /// Save (or update) a specific workspace under its **own name**, without
    /// prompting — the "Save" counterpart to "Save as Workspace…". Updates an
    /// existing saved workspace of the same name in place, else creates one.
    func saveWorkspaceInPlace(_ id: UUID) {
        guard let ws = workspaces.first(where: { $0.id == id }) else { return }
        upsertSavedWorkspace(from: ws, name: ws.name)
    }

    /// Whether a saved workspace already exists matching this workspace's name —
    /// so the menu can offer "Update Saved Workspace" instead of "Save Workspace".
    func isWorkspaceSaved(_ id: UUID) -> Bool {
        guard let ws = workspaces.first(where: { $0.id == id }) else { return false }
        return savedWorkspaces.contains { $0.name == ws.name }
    }

    /// Snapshot `ws` into `savedWorkspaces`, replacing any entry of the same name.
    private func upsertSavedWorkspace(from ws: Workspace, name: String) {
        let tabs = snapshotTabs(for: ws)
        let docks = dockSnapshots(for: ws)
        if let idx = savedWorkspaces.firstIndex(where: { $0.name == name }) {
            savedWorkspaces[idx].tabs = tabs
            savedWorkspaces[idx].isTiled = ws.isTiled
            savedWorkspaces[idx].tileLayout = ws.tileLayout
            savedWorkspaces[idx].docks = docks
        } else {
            savedWorkspaces.append(SavedWorkspace(name: name, tabs: tabs,
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
        // Best-effort: drop any ad-hoc tab passwords this template persisted, so
        // deleting it doesn't leave orphaned Keychain items behind.
        if let ws = savedWorkspaces.first(where: { $0.id == id }) {
            for tab in ws.tabs where tab.credentialID != nil {
                KeychainStore.shared.deletePassword(for: tab.credentialID!)
            }
        }
        // Any profile that launched this saved workspace as its template would
        // otherwise silently fall back to "current workspace" — looking like it
        // "lost its assignment". Preserve the intent by switching those profiles
        // to their own name-based dedicated workspace instead.
        for profile in ProfileStore.shared.profiles where profile.workspaceTemplateID == id {
            var updated = profile
            updated.workspaceTemplateID = nil
            updated.opensInOwnWorkspace = true
            ProfileStore.shared.update(updated)
        }
        savedWorkspaces.removeAll { $0.id == id }
        persistSavedWorkspaces()
    }

    /// Save a workspace as a profile: snapshot its tabs and layout into a
    /// saved-workspace template, then create a profile assigned to that template.
    /// The profile appears in the sidebar / welcome screen; connecting it reopens
    /// the workspace's tabs.
    ///
    /// The new profile's connection identity is seeded from the workspace's
    /// **primary** connection so it isn't shown as a plain local terminal:
    /// - a profile-backed **SSH** tab → the profile clones that connection and
    ///   opens it on connect, with the template adding the other tabs alongside;
    /// - otherwise → a **workspace launcher** that opens no connection of its own
    ///   and rebuilds every tab as-is, its host / user seeded from the first
    ///   remote tab (or left local when the workspace has no remote connection).
    ///
    /// The template's directly-addressed tabs keep their own addresses here;
    /// unifying them onto the profile's host is offered later, in the profile
    /// editor (once the user has set the final host) — see
    /// `templateHasTabsWithDifferentHost` / `normalizeTemplateTabHosts`.
    ///
    /// Returns the new profile (already added to the store), or nil if the
    /// workspace no longer exists.
    @discardableResult
    func saveWorkspaceAsProfile(_ id: UUID, name: String) -> SSHProfile? {
        guard let ws = workspaces.first(where: { $0.id == id }) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? ws.name : trimmed

        // A dedicated template (its own fresh entry, so it never clobbers an
        // unrelated same-named saved workspace the user maintains separately).
        let templateID = createSavedWorkspaceTemplate(from: ws, name: base)

        let liveTabs = ws.tabIDs.compactMap { tid in sessions.first(where: { $0.id == tid }) }
        var profile: SSHProfile

        if let s = liveTabs.first(where: { $0.kind == .ssh && $0.profileID != nil }),
           let pid = s.profileID,
           let src = ProfileStore.shared.profiles.first(where: { $0.id == pid }), !src.isLocal {
            // A real remote profile: clone the ssh connection. Connecting it
            // reconnects the terminal, and the template opens the workspace's other
            // tabs (sftp / vnc / …) alongside, re-pointed to this profile.
            profile = cloneConnection(of: src)
            profile.isWorkspaceLauncher = false
        } else if let s = liveTabs.first(where: {
                    $0.kind == .ssh || $0.kind == .sftp || $0.kind == .vnc }),
                  let seed = connectionSeed(for: s) {
            // A launcher seeded from the first remote tab so it isn't shown as a
            // local terminal. It opens no connection of its own — the template
            // rebuilds every tab as-is (each reconnecting via its own profile).
            profile = seed
            profile.isWorkspaceLauncher = true
        } else {
            // Purely local / non-connection tabs → a local launcher.
            profile = SSHProfile()
            profile.isLocal = true
            profile.isWorkspaceLauncher = true
        }

        profile.name = ProfileStore.shared.uniqueName(for: base)
        profile.icon = "square.stack.3d.up.fill"
        profile.opensInOwnWorkspace = true
        profile.workspaceTemplateID = templateID
        ProfileStore.shared.add(profile)

        // Persist each ad-hoc tab's directly-typed password so the rebuilt tab can
        // reconnect (mqtt / ssh / sftp / vnc). Otherwise it lives only in memory
        // and is lost — forcing a manual re-entry — and an ad-hoc sftp tab couldn't
        // be mounted at all. Profile-backed tabs resolve credentials from their own
        // profile / forward, so they're skipped. `savedWorkspaces[ti].tabs` is
        // built from the same `ws.tabIDs` order as `liveTabs`, so they line up.
        if let ti = savedWorkspaces.firstIndex(where: { $0.id == templateID }) {
            for i in savedWorkspaces[ti].tabs.indices {
                guard savedWorkspaces[ti].tabs[i].profileID == nil,
                      i < liveTabs.count,
                      let pw = capturedAdHocPassword(for: liveTabs[i]), !pw.isEmpty else { continue }
                let credentialID = UUID()
                if KeychainStore.shared.setPassword(pw, for: credentialID) {
                    savedWorkspaces[ti].tabs[i].credentialID = credentialID
                }
            }
            persistSavedWorkspaces()
        }
        return profile
    }

    /// The live password held by an **ad-hoc** connection tab, for persisting into
    /// a workspace-profile template. mqtt / redis / direct-vnc keep it in
    /// `servicePassword`; ad-hoc ssh / sftp use `presetPassword`. Nil for tabs that
    /// never carried one.
    private func capturedAdHocPassword(for s: TerminalSession) -> String? {
        switch s.kind {
        case .mqtt, .redis, .vnc:
            return s.servicePassword.isEmpty ? nil : s.servicePassword
        case .ssh, .sftp:
            return s.presetPassword
        default:
            return nil
        }
    }

    /// Whether `templateID`'s saved workspace has any **directly-addressed**
    /// (ad-hoc) connection tab whose host differs from `host`. Drives the profile
    /// editor's offer to bring a template-backed profile's tabs along when its
    /// host is set or changed (covers both “Save Workspace as Profile” and
    /// duplicating a workspace profile). Profile-backed tabs resolve their address
    /// from their own profile and are ignored. **Browser (web) tabs** count too:
    /// their host is read from (and later rewritten in) their URL, so a workspace
    /// that also opens a device's web UI at an IP is offered for re-pointing.
    func templateHasTabsWithDifferentHost(_ templateID: UUID, than host: String) -> Bool {
        let target = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty,
              let tmpl = savedWorkspaces.first(where: { $0.id == templateID }) else { return false }
        return tmpl.tabs.contains { tab in
            guard tab.profileID == nil else { return false }
            switch tab.kind {
            case .ssh, .sftp, .vnc, .mqtt, .redis:
                let h = (tab.serviceHost ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                return !h.isEmpty && h != target
            case .web:
                guard let s = tab.webURL,
                      let h = TerminalSessionManager.urlHost(of: s) else { return false }
                return h.lowercased() != target
            default:
                return false
            }
        }
    }

    /// Re-point every directly-addressed (ad-hoc) connection tab in `templateID`'s
    /// workspace at `host`, so a template-backed profile's tabs all connect to the
    /// profile's server. Profile-backed tabs are left to their own profile.
    /// **Browser (web) tabs** have the host swapped inside their URL (scheme,
    /// port, path and query preserved), so a device's web UI follows the profile.
    func normalizeTemplateTabHosts(_ templateID: UUID, to host: String) {
        let clean = host.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty,
              let ti = savedWorkspaces.firstIndex(where: { $0.id == templateID }) else { return }
        for i in savedWorkspaces[ti].tabs.indices {
            guard savedWorkspaces[ti].tabs[i].profileID == nil else { continue }
            switch savedWorkspaces[ti].tabs[i].kind {
            case .ssh, .sftp, .vnc, .mqtt, .redis:
                if let h = savedWorkspaces[ti].tabs[i].serviceHost,
                   !h.trimmingCharacters(in: .whitespaces).isEmpty {
                    savedWorkspaces[ti].tabs[i].serviceHost = clean
                }
            case .web:
                if let s = savedWorkspaces[ti].tabs[i].webURL,
                   let swapped = TerminalSessionManager.replacingHost(in: s, with: clean) {
                    savedWorkspaces[ti].tabs[i].webURL = swapped
                }
            default:
                break
            }
        }
        persistSavedWorkspaces()
    }

    /// The host component of a URL string, trimmed — or nil when it carries none
    /// (so a blank/`about:` browser tab is skipped). Used to compare a web tab's
    /// address against a profile's host.
    static func urlHost(of urlString: String) -> String? {
        guard let comps = URLComponents(string: urlString) else { return nil }
        let h = (comps.host ?? "").trimmingCharacters(in: .whitespaces)
        return h.isEmpty ? nil : h
    }

    /// `urlString` with its host replaced by `newHost`, keeping scheme, port,
    /// path, query and fragment. Returns nil when the string has no host to swap.
    static func replacingHost(in urlString: String, with newHost: String) -> String? {
        guard var comps = URLComponents(string: urlString), comps.host != nil else { return nil }
        comps.host = newHost
        return comps.string
    }

    /// Duplicate a saved-workspace template under a fresh id, cloning any per-tab
    /// ad-hoc credentials so the copy neither shares nor (on delete) clobbers the
    /// source's Keychain items. Used when duplicating a profile so the copy gets
    /// its own workspace it can edit — e.g. re-point its tabs at a different host —
    /// without touching the original's. Returns the new template id, or nil.
    @discardableResult
    func duplicateTemplate(_ id: UUID) -> UUID? {
        guard let src = savedWorkspaces.first(where: { $0.id == id }) else { return nil }
        var copy = src
        copy.id = UUID()
        copy.name = uniqueSavedWorkspaceName(for: src.name)
        copy.tabs = src.tabs.map { tab in
            var t = tab
            if let cid = tab.credentialID {
                let newCid = UUID()
                t.credentialID = KeychainStore.shared.copyPassword(from: cid, to: newCid) ? newCid : nil
            }
            return t
        }
        savedWorkspaces.append(copy)
        persistSavedWorkspaces()
        return copy.id
    }

    /// A copy of `p`'s connection settings under a fresh id, with its forwards
    /// re-keyed and its snippets / links dropped — the connection identity used to
    /// seed a workspace profile.
    ///
    /// The fresh ids keep the clone from sharing (or, on delete, clobbering) the
    /// source's Keychain secrets, but each saved password is **copied** across to
    /// the new id so the reproduced connection authenticates exactly like the
    /// original. Without this a profile made via “Save Workspace as Profile”
    /// couldn't bring up its SSH tunnel or its MQTT / Redis service tabs, and
    /// “Mount with FUSE” would fail authentication.
    private func cloneConnection(of p: SSHProfile) -> SSHProfile {
        var c = p
        c.id = UUID()
        c.forwards = c.forwards.map { forward in
            var f = forward
            f.id = UUID()
            KeychainStore.shared.copyPassword(from: forward.id, to: f.id)
            return f
        }
        KeychainStore.shared.copyPassword(from: p.id, to: c.id)
        c.snippets = []
        c.links = []
        return c
    }

    /// The connection identity to seed a workspace **launcher** from: a sanitized
    /// clone of the tab's profile, or — for an ad-hoc tab — a profile built from
    /// its captured host / username / port. Nil if there's nothing to seed.
    private func connectionSeed(for s: TerminalSession) -> SSHProfile? {
        if let pid = s.profileID,
           let p = ProfileStore.shared.profiles.first(where: { $0.id == pid }) {
            return cloneConnection(of: p)
        }
        let host = s.serviceHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        var p = SSHProfile()
        p.host = host
        p.username = s.serviceUsername.trimmingCharacters(in: .whitespaces)
        if let port = s.servicePort { p.port = String(port) }
        return p
    }

    /// Snapshot a workspace into a brand-new `SavedWorkspace` (a launch template),
    /// giving it a name unique among saved workspaces, and return its id.
    private func createSavedWorkspaceTemplate(from ws: Workspace, name: String) -> UUID {
        let template = SavedWorkspace(name: uniqueSavedWorkspaceName(for: name),
                                      tabs: snapshotTabs(for: ws),
                                      isTiled: ws.isTiled,
                                      tileLayout: ws.tileLayout,
                                      docks: dockSnapshots(for: ws))
        savedWorkspaces.append(template)
        persistSavedWorkspaces()
        return template.id
    }

    /// A saved-workspace name that doesn't already exist, suffixing " (2)", " (3)"…
    private func uniqueSavedWorkspaceName(for proposed: String) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? "Workspace" : trimmed
        let existing = Set(savedWorkspaces.map(\.name))
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) (\(n))") { n += 1 }
        return "\(base) (\(n))"
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

    // MARK: - Recently-closed history

    private let recentlyClosedKey = "closedHistory.v1"
    /// How many recently-closed entries to keep (oldest dropped past this).
    private let maxRecentlyClosed = 25

    /// Record a single closed tab so it can be reopened from the welcome screen.
    /// Skips tabs we can't recreate (so the list never shows a dead entry).
    private func recordClosedTab(_ session: TerminalSession) {
        let snap = snapshot(of: session)
        guard canRecreate(snap) else { return }
        let item = ClosedItem(kind: .tab,
                              title: session.title,
                              symbol: session.symbolName,
                              closedAt: Date(),
                              tab: snap)
        pushClosedItem(item)
    }

    /// Record a closed workspace (its tabs + drawers) for later reopening. Skips
    /// empty workspaces and ones with nothing recreatable.
    private func recordClosedWorkspace(_ ws: Workspace) {
        let tabs = snapshotTabs(for: ws).filter { canRecreate($0) }
        guard !tabs.isEmpty else { return }
        let saved = SavedWorkspace(name: ws.name, tabs: tabs,
                                   isTiled: ws.isTiled, tileLayout: ws.tileLayout,
                                   docks: dockSnapshots(for: ws))
        let item = ClosedItem(kind: .workspace,
                              title: ws.name,
                              symbol: "rectangle.stack",
                              closedAt: Date(),
                              workspace: saved)
        pushClosedItem(item)
    }

    /// Whether a snapshot can actually be rebuilt, so we never record a dead entry.
    private func canRecreate(_ snap: SessionSnapshot) -> Bool {
        let hasProfile = snap.profileID.flatMap { id in
            ProfileStore.shared.profiles.contains { $0.id == id }
        } ?? false
        switch snap.kind {
        case .localShell, .web, .finder, .editor, .spreadsheet:
            return true
        case .ssh, .sftp, .vnc:
            return hasProfile || (snap.serviceHost?.isEmpty == false)
        case .mqtt, .redis:
            return hasProfile && snap.servicePort != nil
        }
    }

    private func pushClosedItem(_ item: ClosedItem) {
        recentlyClosed.insert(item, at: 0)
        if recentlyClosed.count > maxRecentlyClosed {
            recentlyClosed.removeLast(recentlyClosed.count - maxRecentlyClosed)
        }
        persistRecentlyClosed()
    }

    /// Reopen a recently-closed entry: a tab returns to the current workspace, a
    /// workspace opens as a new top-level workspace. The entry is then removed
    /// from the list (it's no longer "closed").
    func reopenClosedItem(_ item: ClosedItem) {
        switch item.kind {
        case .tab:
            if let snap = item.tab { recreate(snap) }
        case .workspace:
            if let ws = item.workspace { openSavedWorkspace(ws) }
        }
        removeClosedItem(item)
    }

    /// Forget a single recently-closed entry.
    func removeClosedItem(_ item: ClosedItem) {
        recentlyClosed.removeAll { $0.id == item.id }
        persistRecentlyClosed()
    }

    /// Clear the entire recently-closed history.
    func clearRecentlyClosed() {
        recentlyClosed.removeAll()
        persistRecentlyClosed()
    }

    private func persistRecentlyClosed() {
        if let data = try? JSONEncoder().encode(recentlyClosed) {
            UserDefaults.standard.set(data, forKey: recentlyClosedKey)
        }
    }

    private func loadRecentlyClosed() {
        guard let data = UserDefaults.standard.data(forKey: recentlyClosedKey),
              let items = try? JSONDecoder().decode([ClosedItem].self, from: data) else { return }
        recentlyClosed = items
    }

    // MARK: - Session persistence ("resume last session")

    private let openStateKey = "openState.v2"
    private let legacyOpenSessionsKey = "openSessions.v1"
    private var persistCancellable: AnyCancellable?

    /// Snapshot one workspace's live tabs into codable form (skips dead sessions).
    private func snapshotTabs(for ws: Workspace) -> [SessionSnapshot] {
        ws.tabIDs.compactMap { id -> SessionSnapshot? in
            guard let s = sessions.first(where: { $0.id == id }) else { return nil }
            return snapshot(of: s)
        }
    }

    /// Capture one live session as a codable snapshot — enough to recreate it
    /// later (resume, saved workspace, or the recently-closed history). For an
    /// **ad-hoc** (profile-free) ssh / sftp / vnc tab the target host & username
    /// are captured so it can reconnect; a password is never stored.
    private func snapshot(of s: TerminalSession) -> SessionSnapshot {
        var host: String? = nil
        var user: String? = nil
        if s.profileID == nil,
           s.kind == .ssh || s.kind == .sftp || s.kind == .vnc
            || s.kind == .mqtt || s.kind == .redis {
            let h = s.serviceHost.trimmingCharacters(in: .whitespaces)
            if !h.isEmpty { host = h }
            let u = s.serviceUsername.trimmingCharacters(in: .whitespaces)
            if !u.isEmpty { user = u }
        }
        return SessionSnapshot(kind: s.kind, profileID: s.profileID,
                               webURL: s.webModel?.currentURLString ?? s.finderModel?.currentPath ?? s.textEditorModel?.fileURL?.path ?? s.spreadsheetModel?.fileURL?.path,
                               title: s.title,
                               servicePort: s.servicePort,
                               serviceHost: host, serviceUsername: user,
                               editorBackupID: s.textEditorModel?.id,
                               tabColor: s.tabColor,
                               runOnConnect: s.runOnConnectCommand)
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

    /// Whether `ws` is a throwaway workspace spun up by launching a profile that
    /// has an assigned **workspace template** — the case the user wants kept out
    /// of the resume snapshot (it's regenerated from the template on relaunch).
    /// A workspace the user made themselves, or one from a plain "opens in its own
    /// workspace" profile (no template), returns false so it still persists.
    private func isEphemeralTemplateWorkspace(_ ws: Workspace) -> Bool {
        guard let pid = ws.sourceProfileID,
              let profile = ProfileStore.shared.profiles.first(where: { $0.id == pid })
        else { return false }
        return profile.workspaceTemplateID != nil
    }

    private func writeOpenState() {
        // Flush every editor's unsaved text so the snapshots we take reference an
        // up‑to‑date backup, letting the next launch restore exactly what's open.
        for s in sessions { s.textEditorModel?.flushBackup() }
        // Workspaces launched from a **profile that carries a workspace template**
        // are ephemeral: they're rebuilt from that template every time the profile
        // is launched, so persisting them here would just pile up a fresh resumed
        // copy on each start (the clutter the user asked us to avoid). We skip
        // them — the profile and its template stay, and relaunching the profile
        // recreates the workspace — and save the user's own workspaces plus any
        // plain single‑connection profile workspaces as before.
        let persistable = workspaces.filter { !isEphemeralTemplateWorkspace($0) }
        let snaps = persistable.map { ws -> WorkspaceSnapshot in
            let liveTabIDs = ws.tabIDs.filter { id in sessions.contains { $0.id == id } }
            let selIndex = ws.selectedSessionID.flatMap { liveTabIDs.firstIndex(of: $0) }
            return WorkspaceSnapshot(name: ws.name, isTiled: ws.isTiled,
                                     tileLayout: ws.tileLayout,
                                     selectedIndex: selIndex, tabs: snapshotTabs(for: ws),
                                     docks: dockSnapshots(for: ws),
                                     tabColor: ws.tabColor)
        }
        // Keep the current workspace selected if it survived the filter; if the
        // active one was ephemeral (or there are none), fall back to the first.
        let current = persistable.firstIndex { $0.id == currentWorkspaceID } ?? 0
        let state = OpenStateSnapshot(workspaces: snaps, currentIndex: current)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: openStateKey)
        }
        // Drop backups for editor tabs that are no longer open (closed since the
        // last save), so the backup folder stays in sync with the resume state.
        let liveEditorIDs = Set(sessions.compactMap { $0.textEditorModel?.id })
        EditorBackupStore.shared.prune(keeping: liveEditorIDs)
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
    private func recreate(_ snap: SessionSnapshot, owningProfileID: UUID? = nil) {
        let store = ProfileStore.shared
        let profile = snap.profileID.flatMap { id in store.profiles.first { $0.id == id } }
        // A password persisted for an ad-hoc tab when its workspace was saved as a
        // profile (empty for ordinary resume snapshots, which never store one).
        let adHocPassword = snap.credentialID.flatMap {
            KeychainStore.shared.readPassword(for: $0)
        } ?? ""
        // A profile-free tab rebuilt inside a profile-launched workspace autofills
        // from that launching profile's saved password (Touch ID gated) when it has
        // no captured credential of its own — so its ssh / sftp tabs don't drop to
        // a manual password prompt.
        let owningProfile = owningProfileID.flatMap { id in store.profiles.first { $0.id == id } }
        let autofillSrcID = owningProfile.flatMap {
            KeychainStore.shared.hasPassword(for: $0.id) ? $0.id : nil
        }
        let autofillSrcAuth = owningProfile?.requireAuthForSavedPassword ?? true
        // Remember how many tabs exist so we can tint the one this call creates.
        let tabCountBefore = sessions.count
        switch snap.kind {
        case .localShell:
            if let profile { connect(profile: profile) } else { openLocalShell() }
        case .ssh:
            if let profile { connect(profile: profile) }
            else if let host = snap.serviceHost {
                openAdHocSSH(host: host, port: snap.servicePort ?? 22,
                             username: snap.serviceUsername ?? "", password: adHocPassword,
                             autofillSourceProfileID: autofillSrcID,
                             autofillSourceRequireAuth: autofillSrcAuth)
            }
        case .sftp:
            if let profile { connectSFTP(profile: profile) }
            else if let host = snap.serviceHost {
                openAdHocSFTP(host: host, port: snap.servicePort ?? 22,
                              username: snap.serviceUsername ?? "", password: adHocPassword,
                              credentialID: snap.credentialID,
                              autofillSourceProfileID: autofillSrcID,
                              autofillSourceRequireAuth: autofillSrcAuth)
            }
        case .vnc:
            if let profile { connectVNC(profile: profile) }
            else if let host = snap.serviceHost {
                openAdHocVNC(host: host, port: snap.servicePort ?? 5900,
                             username: snap.serviceUsername ?? "", password: adHocPassword)
            }
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
            let category: ForwardCategory = snap.kind == .redis ? .redis : .mqtt
            if let profile, let port = snap.servicePort,
               let fwd = profile.forwards.first(where: { $0.localEndpoint?.port == port }) {
                openService(category, forward: fwd, profile: profile)
            } else if snap.profileID == nil, let host = snap.serviceHost, let port = snap.servicePort {
                openAdHocService(category: category, host: host, port: port,
                                 username: snap.serviceUsername ?? "", password: adHocPassword)
            }
        case .finder:
            openFinder(path: snap.webURL)
        case .editor:
            openTextEditor(path: snap.webURL, backupID: snap.editorBackupID)
        case .spreadsheet:
            openSpreadsheet(path: snap.webURL)
        }
        // Re-apply the saved tab tint to the tab this call just added (skipped if
        // the open reused an existing tab or created none).
        if let color = snap.tabColor, sessions.count > tabCountBefore {
            sessions.last?.tabColor = color
        }
        // Re-apply a per-tab run-on-launch override (ad-hoc / workspace tabs;
        // profile-backed tabs already inherit the profile's runOnConnect). Set
        // right after creation, before shell output lands, so it fires normally.
        if let cmd = snap.runOnConnect, !cmd.isEmpty,
           snap.profileID == nil, sessions.count > tabCountBefore {
            sessions.last?.runOnConnectCommand = cmd
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
                      tileLayout: $0.tileLayout ?? TileLayout(),
                      tabColor: $0.tabColor)
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
