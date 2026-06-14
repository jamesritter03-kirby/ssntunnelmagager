import Foundation
import ServiceManagement

/// User preferences, persisted in `UserDefaults`, plus the "start at login"
/// integration via `SMAppService`.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private let menuBarOnlyKey = "startInMenuBarOnly"
    private let defaultThemeKey = "defaultThemeID"

    /// Avoids re-entrancy when we correct `launchAtLogin` back to the system value.
    private var isSyncing = false

    /// When true, the app launches into the menu bar without opening the main window.
    @Published var startInMenuBarOnly: Bool {
        didSet { defaults.set(startInMenuBarOnly, forKey: menuBarOnlyKey) }
    }

    /// The theme used for plain local terminals (profiles carry their own theme).
    @Published var defaultThemeID: String {
        didSet { defaults.set(defaultThemeID, forKey: defaultThemeKey) }
    }

    /// When true, the app is registered to start automatically at login.
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isSyncing else { return }
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    private init() {
        startInMenuBarOnly = defaults.bool(forKey: menuBarOnlyKey)
        defaultThemeID = defaults.string(forKey: defaultThemeKey) ?? TerminalTheme.defaultID
        // Reflect the real system state (property observers don't fire in init).
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            let service = SMAppService.mainApp
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            NSLog("SSHTunnelManager: failed to update Start at Login: \(error)")
            // Put the toggle back in sync with reality without re-triggering work.
            DispatchQueue.main.async {
                self.isSyncing = true
                self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
                self.isSyncing = false
            }
        }
    }
}
