import Foundation
import ServiceManagement

/// How a right-click inside a terminal is interpreted. Inspired by
/// RightClickPasteKing's Windows/Linux-style model, but implemented directly
/// against the terminal view we own (so it reads the selection precisely instead
/// of probing for it).
enum TerminalRightClickBehavior: String, CaseIterable, Identifiable {
    /// Always paste the clipboard (PuTTY-style — the previous behavior).
    case paste
    /// Copy the selection if there is one; otherwise paste the clipboard;
    /// otherwise show the context menu (so the click is never wasted).
    case smartCopyPaste
    /// Always show the Copy / Paste / Select All context menu.
    case contextMenu

    var id: String { rawValue }

    /// Short label for the settings picker.
    var label: String {
        switch self {
        case .paste:          return "Paste clipboard"
        case .smartCopyPaste: return "Copy selection, otherwise paste"
        case .contextMenu:    return "Show menu"
        }
    }
}

/// User preferences, persisted in `UserDefaults`, plus the "start at login"
/// integration via `SMAppService`.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private let menuBarOnlyKey = "startInMenuBarOnly"
    private let defaultThemeKey = "defaultThemeID"
    private let defaultFontSizeKey = "defaultFontSize"
    private let resumeLastSessionKey = "resumeLastSession"
    private let terminalRightClickKey = "terminalRightClickBehavior"
    private let deselectAfterCopyKey = "deselectTerminalAfterCopy"

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

    /// How a right-click in a terminal behaves (paste, smart copy/paste, or menu).
    @Published var terminalRightClick: TerminalRightClickBehavior {
        didSet { defaults.set(terminalRightClick.rawValue, forKey: terminalRightClickKey) }
    }

    /// When a smart right-click copies a selection, also clear the selection so the
    /// next right-click pastes — completing the one-handed copy→paste cycle.
    @Published var deselectTerminalAfterCopy: Bool {
        didSet { defaults.set(deselectTerminalAfterCopy, forKey: deselectAfterCopyKey) }
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
        let storedRightClick = defaults.string(forKey: terminalRightClickKey)
        terminalRightClick = storedRightClick
            .flatMap(TerminalRightClickBehavior.init(rawValue:)) ?? .smartCopyPaste
        deselectTerminalAfterCopy = defaults.object(forKey: deselectAfterCopyKey) as? Bool ?? true
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
