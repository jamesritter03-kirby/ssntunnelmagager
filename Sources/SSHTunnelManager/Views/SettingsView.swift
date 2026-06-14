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
            } header: {
                Text("Startup")
            } footer: {
                Text("With “Launch into the menu bar”, the app starts as a menu bar item with no window or Dock icon. Use the menu bar → Show Main Window to open it. This applies the next time the app launches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Terminal") {
                Picker("Default theme for local terminals", selection: $settings.defaultThemeID) {
                    ForEach(TerminalTheme.all) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                ThemePreview(theme: TerminalTheme.theme(id: settings.defaultThemeID))
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
