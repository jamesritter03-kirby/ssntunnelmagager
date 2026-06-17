import Foundation
import ServiceManagement

/// User preferences, persisted in `UserDefaults`, plus the "start at login"
/// integration via `SMAppService`.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private let menuBarOnlyKey = "startInMenuBarOnly"
    private let defaultThemeKey = "defaultThemeID"
    private let defaultFontSizeKey = "defaultFontSize"
    private let resumeLastSessionKey = "resumeLastSession"

    /// Avoids re-entrancy when we correct `launchAtLogin` back to the system value.
    private var isSyncing = false

    /// When true, the app launches into the menu bar without opening the main window.
    @Published var startInMenuBarOnly: Bool {
        didSet { defaults.set(startInMenuBarOnly, forKey: menuBarOnlyKey) }
    }

    /// When true, the app reopens the tabs that were open when it last quit.
    @Published var resumeLastSession: Bool {
        didSet { defaults.set(resumeLastSession, forKey: resumeLastSessionKey) }
    }

    /// The theme used for plain local terminals (profiles carry their own theme).
    @Published var defaultThemeID: String {
        didSet { defaults.set(defaultThemeID, forKey: defaultThemeKey) }
    }

    /// The text size (points) for plain local terminals (profiles carry their own).
    @Published var defaultFontSize: Double {
        didSet {
            let clamped = TerminalFontMetrics.clamp(defaultFontSize)
            if clamped != defaultFontSize { defaultFontSize = clamped; return }
            defaults.set(defaultFontSize, forKey: defaultFontSizeKey)
        }
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
        resumeLastSession = defaults.object(forKey: resumeLastSessionKey) as? Bool ?? true
        defaultThemeID = defaults.string(forKey: defaultThemeKey) ?? TerminalTheme.defaultID
        let storedFont = defaults.object(forKey: defaultFontSizeKey) as? Double ?? TerminalFontMetrics.default
        defaultFontSize = TerminalFontMetrics.clamp(storedFont)
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
