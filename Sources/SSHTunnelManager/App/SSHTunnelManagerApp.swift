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
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Local Terminal") { sessions.openLocalShell() }
                    .keyboardShortcut("t", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Close Tab") { sessions.closeSelected() }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(sessions.selectedSession == nil)
            }
            CommandMenu("Commands") {
                Button("Command Palette…") { CommandPaletteModel.shared.show() }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
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
            CommandGroup(after: .windowArrangement) {
                Button("Detach Tab into New Window") {
                    if let session = sessions.selectedSession {
                        DetachedTerminalController.shared.detach(session)
                    }
                }
                .keyboardShortcut("d", modifiers: [.command, .control])
                .disabled(sessions.selectedSession == nil)

                Toggle("Tile Tabs", isOn: $sessions.isTiled)
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

    // Runs before the SwiftUI window is shown — the right place to suppress it.
    func applicationWillFinishLaunching(_ notification: Notification) {
        if AppSettings.shared.startInMenuBarOnly {
            WindowManager.shared.pendingInitialHide = true
            NSApp.setActivationPolicy(.accessory)   // no Dock icon / window flash
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        if !AppSettings.shared.startInMenuBarOnly {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // Keep running in the menu bar even when the main window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Reopen the main window when the user clicks the Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowManager.shared.showMainWindow() }
        return true
    }
}
