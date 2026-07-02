import SwiftUI

/// The ⌘, preferences panel. The same toggles also live in the menu bar menu.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updater = UpdaterController.shared

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
    }

    private static var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
