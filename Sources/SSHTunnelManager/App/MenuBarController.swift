import AppKit
import Combine

/// Manages the macOS menu bar (status bar) item and its quick-access menu.
///
/// The menu is rebuilt every time it opens (`menuNeedsUpdate`) so it always
/// reflects the current profiles and running sessions.
final class MenuBarController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let store: ProfileStore
    private let sessions: TerminalSessionManager
    private let settings = AppSettings.shared
    private let statusItem: NSStatusItem

    private var cancellables = Set<AnyCancellable>()
    private var sessionCancellables: [AnyCancellable] = []

    init(store: ProfileStore, sessions: TerminalSessionManager) {
        self.store = store
        self.sessions = sessions
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let symbol = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted",
                                 accessibilityDescription: "Remote Stuff")
                ?? NSImage(systemSymbolName: "network", accessibilityDescription: "Remote Stuff")
            symbol?.isTemplate = true   // adapts to light/dark menu bar
            button.image = symbol
            button.toolTip = "Remote Stuff"
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        observeSessions()
        updateStatusItem()
    }

    // MARK: - Active-tunnel badge

    /// Re-subscribe to every session's `isRunning` whenever the set of sessions
    /// changes, so the badge tracks tunnels coming up and going down live.
    private func observeSessions() {
        sessions.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] list in
                guard let self else { return }
                self.sessionCancellables = list.map { session in
                    session.$isRunning
                        .receive(on: RunLoop.main)
                        .sink { [weak self] _ in self?.updateStatusItem() }
                }
                self.updateStatusItem()
            }
            .store(in: &cancellables)
    }

    private var activeTunnelCount: Int {
        sessions.sessions.filter { $0.kind == .ssh && $0.isRunning }.count
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let active = activeTunnelCount
        if active > 0 {
            button.title = " \(active)"
            button.contentTintColor = .systemGreen
            button.toolTip = "Remote Stuff — \(active) active tunnel\(active == 1 ? "" : "s")"
        } else {
            button.title = ""
            button.contentTintColor = nil
            button.toolTip = "Remote Stuff"
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        addDisabled("Remote Stuff", to: menu)
        menu.addItem(.separator())

        addAction("Show Main Window", #selector(showWindow), to: menu)
        addAction("New Local Terminal", #selector(newTerminal), to: menu)

        // MARK: Profiles
        menu.addItem(.separator())
        addDisabled("Connect", to: menu)

        if store.profiles.isEmpty {
            addDisabled("  No profiles yet", to: menu)
        } else {
            for profile in store.profiles {
                let item = addAction(profile.name, #selector(connectProfile(_:)), to: menu)
                item.representedObject = profile.id
                item.indentationLevel = 1
                item.image = NSImage(systemSymbolName: profile.isWorkspaceLauncher
                                     ? "square.stack.3d.up.fill" : "network",
                                     accessibilityDescription: nil)
                if isActive(profile) {
                    item.state = .on            // checkmark = a tunnel is live
                    item.toolTip = "Connected — click to open another session"
                }

                // A submenu of per-profile actions (edit / SFTP / VNC), so the
                // menu bar can do more than just connect.
                let submenu = NSMenu()
                let connect = NSMenuItem(title: "Connect", action: #selector(connectProfile(_:)), keyEquivalent: "")
                connect.target = self
                connect.representedObject = profile.id
                submenu.addItem(connect)

                let edit = NSMenuItem(title: "Edit…", action: #selector(editProfile(_:)), keyEquivalent: "")
                edit.target = self
                edit.representedObject = profile.id
                submenu.addItem(edit)

                if !profile.isLocal {
                    let sftp = NSMenuItem(title: "Open SFTP", action: #selector(openSFTP(_:)), keyEquivalent: "")
                    sftp.target = self
                    sftp.representedObject = profile.id
                    submenu.addItem(sftp)

                    let vnc = NSMenuItem(title: "Open VNC", action: #selector(openVNC(_:)), keyEquivalent: "")
                    vnc.target = self
                    vnc.representedObject = profile.id
                    submenu.addItem(vnc)
                }
                item.submenu = submenu
            }
        }
        let newProfile = addAction("New Profile…", #selector(newProfile), to: menu)
        newProfile.indentationLevel = 1
        newProfile.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)

        // MARK: Workspaces
        if !sessions.savedWorkspaces.isEmpty {
            menu.addItem(.separator())
            addDisabled("Open Workspace", to: menu)
            for saved in sessions.savedWorkspaces {
                let item = addAction("\(saved.name) (\(saved.tabs.count))",
                                     #selector(openWorkspace(_:)), to: menu)
                item.representedObject = saved.id
                item.indentationLevel = 1
                item.image = NSImage(systemSymbolName: "square.stack.3d.up.fill",
                                     accessibilityDescription: nil)
            }
        }

        // MARK: Active sessions
        if !sessions.sessions.isEmpty {
            menu.addItem(.separator())
            addDisabled("Sessions", to: menu)
            for session in sessions.sessions {
                let dot = session.isRunning ? "●  " : "○  "
                let item = addAction(dot + session.title, #selector(focusSession(_:)), to: menu)
                item.representedObject = session.id
                item.indentationLevel = 1

                let submenu = NSMenu()
                let focus = NSMenuItem(title: "Focus", action: #selector(focusSession(_:)), keyEquivalent: "")
                focus.target = self
                focus.representedObject = session.id
                submenu.addItem(focus)

                let close = NSMenuItem(title: session.isRunning ? "Disconnect" : "Close Tab",
                                       action: #selector(closeSession(_:)), keyEquivalent: "")
                close.target = self
                close.representedObject = session.id
                submenu.addItem(close)

                item.submenu = submenu
            }

            if activeTunnelCount > 0 {
                let item = addAction("Disconnect All Tunnels", #selector(disconnectAll), to: menu)
                item.image = NSImage(systemSymbolName: "bolt.slash", accessibilityDescription: nil)
                item.toolTip = "Close every running SSH tunnel"
            }
        }

        menu.addItem(.separator())
        addDisabled("Options", to: menu)
        let login = addAction("Start at Login", #selector(toggleLaunchAtLogin), to: menu)
        login.state = settings.launchAtLogin ? .on : .off
        let mbOnly = addAction("Launch to Menu Bar", #selector(toggleMenuBarOnly), to: menu)
        mbOnly.state = settings.startInMenuBarOnly ? .on : .off
        mbOnly.toolTip = "Start in the menu bar without opening the window (applies next launch)."

        menu.addItem(.separator())
        let updates = addAction("Check for Updates…", #selector(checkForUpdates), to: menu)
        updates.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        updates.toolTip = "Check for a newer version of Remote Stuff"

        let quit = NSMenuItem(title: "Quit Remote Stuff",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: - Dock menu

    /// Builds the menu shown when the user right-clicks (or Control-clicks) the
    /// app's Dock icon. Mirrors the quick actions of the status-bar menu, with
    /// submenus to connect a **profile** or open a saved **workspace**. Rebuilt on
    /// every request (AppKit calls `applicationDockMenu` each time), so it always
    /// reflects the current profiles and saved workspaces.
    func buildDockMenu() -> NSMenu {
        let menu = NSMenu()

        // Profiles — inline if only a few, otherwise still inline (Dock menus are
        // fine with a modest list). Each connects the profile.
        if store.profiles.isEmpty {
            addDisabled("No profiles yet", to: menu)
        } else {
            let header = NSMenuItem(title: "Connect Profile", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for profile in store.profiles {
                let item = addAction("  " + profile.name, #selector(connectProfile(_:)), to: menu)
                item.representedObject = profile.id
                item.image = NSImage(systemSymbolName: profile.isWorkspaceLauncher
                                     ? "square.stack.3d.up.fill" : "network",
                                     accessibilityDescription: nil)
                if isActive(profile) { item.state = .on }
            }
        }

        // Saved workspaces — each reopens its tabs.
        if !sessions.savedWorkspaces.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Open Workspace", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for saved in sessions.savedWorkspaces {
                let item = addAction("  \(saved.name) (\(saved.tabs.count))",
                                     #selector(openWorkspace(_:)), to: menu)
                item.representedObject = saved.id
                item.image = NSImage(systemSymbolName: "square.stack.3d.up.fill",
                                     accessibilityDescription: nil)
            }
        }

        return menu
    }

    @objc private func openWorkspace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let saved = sessions.savedWorkspaces.first(where: { $0.id == id }) else { return }
        WindowManager.shared.showMainWindow()
        sessions.openSavedWorkspace(saved)
    }

    // MARK: - Menu builders

    @discardableResult
    private func addAction(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func addDisabled(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func isActive(_ profile: SSHProfile) -> Bool {
        sessions.sessions.contains { $0.profileID == profile.id && $0.isRunning }
    }

    // MARK: - Actions

    @objc private func showWindow() {
        WindowManager.shared.showMainWindow()
    }

    @objc private func newTerminal() {
        WindowManager.shared.showMainWindow()
        sessions.openLocalShell()
    }

    @objc private func connectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let profile = store.profiles.first(where: { $0.id == id }) else { return }
        WindowManager.shared.showMainWindow()
        sessions.connect(profile: profile)
    }

    @objc private func editProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let profile = store.profiles.first(where: { $0.id == id }) else { return }
        WindowManager.shared.showMainWindow()
        ProfileEditCoordinator.shared.profileToEdit = profile
    }

    @objc private func newProfile() {
        WindowManager.shared.showMainWindow()
        ProfileEditCoordinator.shared.profileToEdit = SSHProfile()
    }

    @objc private func openSFTP(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let profile = store.profiles.first(where: { $0.id == id }) else { return }
        WindowManager.shared.showMainWindow()
        sessions.connectSFTP(profile: profile)
    }

    @objc private func openVNC(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let profile = store.profiles.first(where: { $0.id == id }) else { return }
        WindowManager.shared.showMainWindow()
        sessions.connectVNC(profile: profile)
    }

    @objc private func focusSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let session = sessions.sessions.first(where: { $0.id == id }) else { return }
        WindowManager.shared.showMainWindow()
        sessions.select(session)
    }

    @objc private func closeSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let session = sessions.sessions.first(where: { $0.id == id }) else { return }
        sessions.close(session)
    }

    @objc private func toggleLaunchAtLogin() {
        settings.launchAtLogin.toggle()
    }

    @objc private func toggleMenuBarOnly() {
        settings.startInMenuBarOnly.toggle()
    }

    @objc private func disconnectAll() {
        sessions.disconnectAllTunnels()
    }

    @objc private func checkForUpdates() {
        WindowManager.shared.showMainWindow()   // so Sparkle's dialog has a home
        UpdaterController.shared.checkForUpdates()
    }

    // Grey out "Check for Updates…" while Sparkle isn't ready (e.g. a check is
    // already in flight); every other item stays enabled.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) {
            return UpdaterController.shared.canCheckForUpdates
        }
        return true
    }
}
