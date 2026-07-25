import SwiftUI

/// The ⌘, preferences panel. The same toggles also live in the menu bar menu.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updater = UpdaterController.shared

    /// The current "open where?" default for Welcome-screen launches, loaded from
    /// the same remembered choice the launch prompt writes.
    @State private var welcomeLaunch: WelcomeLaunchChoice = .ask
    /// The name of the remembered workspace, when the default targets a specific one.
    @State private var rememberedWorkspaceName: String?

    private enum WelcomeLaunchChoice: Hashable { case ask, newWorkspace, existing }

    var body: some View {
        Form {
            Section {
                Toggle("Start at login", isOn: $settings.launchAtLogin)
                Toggle("Launch into the menu bar (don't open the window at startup)",
                       isOn: $settings.startInMenuBarOnly)
                Toggle("Resume last session at startup", isOn: $settings.resumeLastSession)
            } header: {
                HStack {
                    Text("Startup")
                    Spacer()
                    HelpButton(articleID: "settings")
                }
            } footer: {
                Text("With “Launch into the menu bar”, the app starts as a menu bar item with no window or Dock icon. Use the menu bar → Show Main Window to open it. “Resume last session” reopens the tabs that were open when you last quit. Both apply the next time the app launches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Default theme for local terminals", selection: $settings.defaultThemeID) {
                    ForEach(TerminalTheme.all) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                ThemePreview(theme: TerminalTheme.theme(id: settings.defaultThemeID))
                Stepper(value: $settings.defaultFontSize,
                        in: TerminalFontMetrics.min...TerminalFontMetrics.max,
                        step: TerminalFontMetrics.step) {
                    Text("Default text size for local terminals: \(Int(settings.defaultFontSize)) pt")
                }
                Picker("Right-click", selection: $settings.terminalRightClick) {
                    ForEach(TerminalRightClickBehavior.allCases) { behavior in
                        Text(behavior.label).tag(behavior)
                    }
                }
                if settings.terminalRightClick == .smartCopyPaste {
                    Toggle("Clear the selection after a right-click copy",
                           isOn: $settings.deselectTerminalAfterCopy)
                }
            } header: {
                Text("Terminal")
            } footer: {
                Text("“Copy selection, otherwise paste” copies highlighted text on right-click, pastes the clipboard when nothing is selected, and shows a Copy/Paste menu when there's neither — so a right-click is never wasted. While an app has mouse reporting on (vim, htop, tmux…), the right-click is passed through to it instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Default theme for new text editors", selection: $settings.defaultEditorThemeID) {
                    ForEach(EditorTheme.all) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
            } header: {
                Text("Editor")
            } footer: {
                Text("The colour theme for new text‑editor tabs. Each tab can still switch its own theme from the editor toolbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Launching from the Welcome tab", selection: $welcomeLaunch) {
                    Text("Ask each time").tag(WelcomeLaunchChoice.ask)
                    Text("Always open in a new workspace").tag(WelcomeLaunchChoice.newWorkspace)
                    if let name = rememberedWorkspaceName {
                        Text("Always open in “\(name)”").tag(WelcomeLaunchChoice.existing)
                    }
                }
                .onChange(of: welcomeLaunch) { applyWelcomeLaunch($0) }
            } header: {
                Text("Welcome Screen")
            } footer: {
                Text("The pinned Welcome tab can open a new tab, connection or profile into a new or existing workspace. Choose “Ask each time” to be prompted, or set a default here. This is the same choice the prompt's “Remember this choice” option controls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                HStack {
                    Text("Version \(Self.appVersion)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Updates are downloaded from the app's release feed and verified with a cryptographic signature before installing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 480)
        .onAppear { loadWelcomeLaunch() }
    }

    /// Read the current Welcome-launch default so the picker reflects it.
    private func loadWelcomeLaunch() {
        let sessions = TerminalSessionManager.shared
        switch sessions.rememberedLaunchTarget {
        case .none:
            welcomeLaunch = .ask
            rememberedWorkspaceName = nil
        case .new:
            welcomeLaunch = .newWorkspace
            rememberedWorkspaceName = nil
        case .existing(let id):
            welcomeLaunch = .existing
            rememberedWorkspaceName = sessions.workspaces.first { $0.id == id }?.name
        }
    }

    /// Persist the chosen Welcome-launch default.
    private func applyWelcomeLaunch(_ choice: WelcomeLaunchChoice) {
        let sessions = TerminalSessionManager.shared
        switch choice {
        case .ask: sessions.rememberedLaunchTarget = nil
        case .newWorkspace: sessions.rememberedLaunchTarget = .new
        case .existing: break // keep the already-remembered workspace
        }
    }

    private static var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
