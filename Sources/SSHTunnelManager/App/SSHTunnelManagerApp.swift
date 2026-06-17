import SwiftUI
import AppKit

@main
struct SSHTunnelManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ProfileStore.shared
    @StateObject private var sessions = TerminalSessionManager.shared
    @StateObject private var updater = UpdaterController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(sessions)
                .frame(minWidth: 940, minHeight: 580)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .sidebar) {
                Button("Show/Hide Sidebar") { SidebarModel.shared.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Local Terminal") { sessions.openLocalShell() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("New Browser Tab") { sessions.openBlankWeb() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Button("Close Tab") { sessions.closeSelected() }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(sessions.selectedSession == nil)
            }
            CommandGroup(after: .importExport) {
                Button("Import Profiles…") {
                    ProfileTransfer.importFlow(into: store)
                }
                Button("Export All Profiles…") {
                    ProfileTransfer.exportFlow(store.profiles, suggestedName: "SSH Tunnels.json")
                }
                .disabled(store.profiles.isEmpty)
            }
            CommandMenu("Commands") {
                Button("Command Palette…") { CommandPaletteModel.shared.show() }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Disconnect") { sessions.disconnectSelected() }
                    .disabled(sessions.selectedSession == nil)
                Button("Disconnect All Tunnels") { sessions.disconnectAllTunnels() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("Increase Terminal Text") { sessions.increaseFontSize() }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(sessions.selectedSession == nil)
                Button("Decrease Terminal Text") { sessions.decreaseFontSize() }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(sessions.selectedSession == nil)
                Button("Actual Size") { sessions.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(sessions.selectedSession == nil)
            }
            CommandMenu("Workspace") {
                Button("New Workspace") { sessions.addWorkspace() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Close Workspace") {
                    sessions.closeWorkspace(sessions.currentWorkspaceID)
                }
                .disabled(sessions.workspaces.count < 2)
                Divider()
                Button("Next Workspace") { sessions.selectNextWorkspace() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(sessions.workspaces.count < 2)
                Button("Previous Workspace") { sessions.selectPreviousWorkspace() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled(sessions.workspaces.count < 2)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Detach Tab into New Window") {
                    if let session = sessions.selectedSession {
                        DetachedTerminalController.shared.detach(session)
                    }
                }
                .keyboardShortcut("d", modifiers: [.command, .control])
                .disabled(sessions.selectedSession == nil)

                Toggle("Tile Tabs", isOn: Binding(
                    get: { sessions.isTiled },
                    set: { sessions.isTiled = $0 }))
                    .keyboardShortcut("t", modifiers: [.command, .control])
                    .disabled(sessions.attachedSessions.count < 2)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    /// True when another copy was already running and this one is bowing out.
    private var isDuplicateInstance = false

    // Runs before the SwiftUI window is shown — the right place to suppress it.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Single-instance check: if another copy is already running, activate it and quit.
        let dominated = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        if let existing = dominated.first {
            isDuplicateInstance = true
            existing.activate(options: [.activateIgnoringOtherApps])
            // Slight delay so the other instance comes forward before we exit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
            return
        }

        if AppSettings.shared.startInMenuBarOnly {
            WindowManager.shared.pendingInitialHide = true
            NSApp.setActivationPolicy(.accessory)   // no Dock icon / window flash
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A duplicate launch is on its way out — don't touch shared state.
        guard !isDuplicateInstance else { return }

        // If we're running from a read-only / translocated spot (which breaks
        // auto-update and leaves duplicate copies), offer to move to /Applications
        // and relaunch — this may terminate the app, so do it first.
        InstallLocationGuard.checkAndOfferMoveToApplications()

        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        // The always-available menu bar (status bar) item.
        menuBarController = MenuBarController(store: .shared, sessions: .shared)

        // Restore the previous session's tabs (if enabled), then keep saving the
        // open set so the next launch can resume exactly where we left off.
        TerminalSessionManager.shared.restoreLastSessionIfEnabled()
        TerminalSessionManager.shared.beginPersistingOpenSessions()

        if !AppSettings.shared.startInMenuBarOnly {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // Save the open tabs one last time so they can be resumed next launch.
    func applicationWillTerminate(_ notification: Notification) {
        guard !isDuplicateInstance else { return }
        TerminalSessionManager.shared.persistOpenSessions()
    }

    // Keep running in the menu bar even when the main window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Reopen the main window when the user clicks the Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // We show the existing main window ourselves; return false so AppKit
            // doesn't *also* create a fresh window (which would be a duplicate).
            WindowManager.shared.showMainWindow()
            return false
        }
        return true
    }
}
