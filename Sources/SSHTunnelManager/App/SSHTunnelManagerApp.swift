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
                Button("New Finder Tab") { sessions.openFinder() }
                Button("New Text Editor") { sessions.openTextEditor() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Spreadsheet") { sessions.openSpreadsheet() }
                Divider()
                Button("New Remote Terminal…") { RemoteConnectionModel.shared.present(.ssh) }
                Button("New SFTP Connection…") { RemoteConnectionModel.shared.present(.sftp) }
                Button("New MQTT Connection…") { ServiceConnectionModel.shared.present(.mqtt) }
                Button("New Redis Connection…") { ServiceConnectionModel.shared.present(.redis) }
                Button("New VNC Connection…") { VNCConnectionModel.shared.present() }
                Divider()
                Button("Browse ZeroTier Devices…") { ZeroTierBrowserModel.shared.present() }
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
                Button("Import from ~/.ssh/config…") {
                    SSHConfigImporter.importFlow(into: store)
                }
                Button("Export All Profiles…") {
                    ProfileTransfer.exportFlow(store.profiles, suggestedName: "SSH Tunnels.json")
                }
                .disabled(store.profiles.isEmpty)
                Divider()
                Button("Manage Known Hosts…") { KnownHostsModel.shared.present() }
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
                Toggle("Broadcast Input to All Terminals", isOn: Binding(
                    get: { sessions.broadcastInput },
                    set: { sessions.broadcastInput = $0 }))
                    .keyboardShortcut("b", modifiers: [.command, .control])
                Divider()
                Button("Set Up Passwordless Login…") { sessions.setUpKeyLoginPrompt() }
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
                    .disabled(sessions.centerSessions.count < 2)

                Button("Dock Tab to Left") {
                    if let session = sessions.selectedSession {
                        sessions.dock(session, to: .left)
                    }
                }
                .keyboardShortcut("[", modifiers: [.command, .control])
                .disabled(sessions.selectedSession == nil)

                Button("Dock Tab to Right") {
                    if let session = sessions.selectedSession {
                        sessions.dock(session, to: .right)
                    }
                }
                .keyboardShortcut("]", modifiers: [.command, .control])
                .disabled(sessions.selectedSession == nil)

                Button("Dock Tab to Top") {
                    if let session = sessions.selectedSession {
                        sessions.dock(session, to: .top)
                    }
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                .disabled(sessions.selectedSession == nil)

                Button("Dock Tab to Bottom") {
                    if let session = sessions.selectedSession {
                        sessions.dock(session, to: .bottom)
                    }
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                .disabled(sessions.selectedSession == nil)
            }
            CommandGroup(replacing: .help) {
                Button("Remote Stuff Help") {
                    HelpWindowController.shared.show(.article("getting-started"))
                }
                .keyboardShortcut("?", modifiers: .command)
                Button("Keyboard Shortcuts") {
                    HelpWindowController.shared.show(.article("shortcuts"))
                }
                Divider()
                Button("Release Notes") {
                    HelpWindowController.shared.show(.releaseNotes)
                }
                Button("Download Older Versions…") {
                    HelpWindowController.shared.show(.olderVersions)
                }
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Divider()
                Button("Project Page on GitHub") {
                    NSWorkspace.shared.open(ReleaseCatalog.homePageURL)
                }
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
        // We manage our own tab bar, so suppress AppKit's native window tabbing —
        // this also removes the “Show/Hide Tab Bar” item it injects into the View menu.
        NSWindow.allowsAutomaticWindowTabbing = false

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

        // F12 / ⌥⌘I opens the Web Inspector in the focused browser tab.
        WebInspectorHotkey.install()

        // Restore the previous session's tabs (if enabled), then keep saving the
        // open set so the next launch can resume exactly where we left off.
        TerminalSessionManager.shared.restoreLastSessionIfEnabled()
        TerminalSessionManager.shared.beginPersistingOpenSessions()
        // Bring up any profiles the user asked to auto-connect at launch.
        TerminalSessionManager.shared.autoConnectProfilesOnLaunch()

        if !AppSettings.shared.startInMenuBarOnly {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // Warn before quitting if a profile editor is open with unsaved edits.
    // (Committed profiles auto-save, so an open editor is the only unsaved state.)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isDuplicateInstance else { return .terminateNow }
        let coordinator = ProfileEditCoordinator.shared
        // A quit we re-issued ourselves after the user chose Save / Don't Save.
        if coordinator.isForceQuitting { return .terminateNow }
        guard coordinator.hasUnsavedEdits else { return .terminateNow }
        // Cancel this quit and ask via a SwiftUI alert instead — running an AppKit
        // modal from here is unreliable for Apple-Event quits (Dock, osascript).
        // The user's choice re-issues a clean quit through `isForceQuitting`.
        NSApp.activate(ignoringOtherApps: true)
        coordinator.requestQuitConfirmation()
        return .terminateCancel
    }

    // Save the open tabs one last time so they can be resumed next launch.
    func applicationWillTerminate(_ notification: Notification) {
        guard !isDuplicateInstance else { return }
        TerminalSessionManager.shared.persistOpenSessions()
        // Then reap every tunnel's process so none survives the app holding a
        // forwarded port — otherwise the next launch's reconnect collides and dies.
        TerminalSessionManager.shared.shutDownAllProcesses()
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
