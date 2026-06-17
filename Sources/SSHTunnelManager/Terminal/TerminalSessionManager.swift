import Foundation
import SwiftUI
import AppKit
import Combine

/// Owns the open terminal tabs and routes "open shell" / "connect profile" actions.
final class TerminalSessionManager: ObservableObject {
    @Published var sessions: [TerminalSession] = []
    @Published var selectedSessionID: UUID?

    static let shared = TerminalSessionManager()
    private init() {}

    var selectedSession: TerminalSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    /// IDs of sessions currently shown in their own floating window.
    @Published var detachedSessionIDs: Set<UUID> = []

    /// When true, the main window shows every attached tab tiled in a grid
    /// instead of one at a time. Persisted across launches.
    @Published var isTiled: Bool = UserDefaults.standard.bool(forKey: "tileTerminals") {
        didSet { UserDefaults.standard.set(isTiled, forKey: "tileTerminals") }
    }

    /// Sessions shown as tabs in the main window (everything not detached).
    var attachedSessions: [TerminalSession] {
        sessions.filter { !detachedSessionIDs.contains($0.id) }
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

    private func addAndStart(_ session: TerminalSession) {
        sessions.append(session)
        selectedSessionID = session.id
        // Start on the next runloop turn so the view is mounted with a real size.
        DispatchQueue.main.async {
            session.start()
        }
    }

    func close(_ session: TerminalSession) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions.remove(at: idx)
        detachedSessionIDs.remove(session.id)
        // Removing the last strong reference tears down the PTY, which sends SIGHUP
        // to the child process (ssh) and cleans up its tunnels.
        if selectedSessionID == session.id {
            selectedSessionID = (attachedSessions[safe: idx] ?? attachedSessions.last)?.id
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

    func select(_ session: TerminalSession) {
        selectedSessionID = session.id
    }

    /// Mark a session as detached (shown in its own window) and move tab focus.
    func markDetached(_ session: TerminalSession) {
        detachedSessionIDs.insert(session.id)
        if selectedSessionID == session.id {
            selectedSessionID = attachedSessions.first?.id
        }
    }

    /// Mark a session as re-attached to the main window's tab bar and focus it.
    func markAttached(_ session: TerminalSession) {
        detachedSessionIDs.remove(session.id)
        selectedSessionID = session.id
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

    /// Move an attached session (tab) from one index to another.
    func moveAttachedSession(from fromIndex: Int, to toIndex: Int) {
        let attached = attachedSessions
        guard fromIndex != toIndex,
              fromIndex >= 0, fromIndex < attached.count,
              toIndex >= 0, toIndex < attached.count else { return }
        var newOrder = attached.map { $0.id }
        let moving = newOrder.remove(at: fromIndex)
        newOrder.insert(moving, at: toIndex)
        // Reorder sessions array to match the new attached order, keeping detached sessions in place
        var reordered: [TerminalSession] = []
        var attachedIdx = 0
        for session in sessions {
            if detachedSessionIDs.contains(session.id) {
                reordered.append(session)
            } else {
                if attachedIdx < newOrder.count,
                   let s = attached.first(where: { $0.id == newOrder[attachedIdx] }) {
                    reordered.append(s)
                    attachedIdx += 1
                }
            }
        }
        sessions = reordered
    }
}
