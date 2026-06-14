import Foundation
import SwiftUI
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
            theme: TerminalTheme.theme(id: AppSettings.shared.defaultThemeID)
        )
        addAndStart(session)
    }

    /// Open a new tab running `ssh` with the profile's tunnel configuration.
    func connect(profile: SSHProfile) {
        let args = SSHCommandBuilder.arguments(for: profile)
        let session = TerminalSession(
            kind: .ssh,
            title: profile.name,
            executable: SSHCommandBuilder.sshPath,
            args: args,
            commandPreview: SSHCommandBuilder.commandPreview(for: profile),
            profileID: profile.id,
            theme: TerminalTheme.theme(id: profile.theme),
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
}
