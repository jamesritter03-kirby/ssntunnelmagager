import AppKit

/// Holds a reference to the main window so the menu bar / Dock can re-show it
/// after it has been closed (the app keeps running as a status-bar app).
final class WindowManager {
    static let shared = WindowManager()
    private init() {}

    /// Strong reference so the window (and its SwiftUI content) survives a close.
    private var mainWindow: NSWindow?

    /// When true, the first window registered at launch is hidden immediately.
    /// Used for menu-bar-only / login launches so the window never flashes.
    var pendingInitialHide = false

    func register(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        window.isReleasedWhenClosed = false
        mainWindow = window
        if pendingInitialHide {
            pendingInitialHide = false
            window.orderOut(nil)
        }
    }

    /// Bring the main window to the front, finding it again if necessary.
    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if mainWindow == nil {
            mainWindow = NSApp.windows.first {
                $0.styleMask.contains(.titled) && $0.contentView != nil
            }
        }
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
