import AppKit

/// Holds a reference to the main window so the menu bar / Dock can re-show it
/// after it has been closed (the app keeps running as a status-bar app).
final class WindowManager {
    static let shared = WindowManager()
    private init() {}

    /// Strong reference so the window (and its SwiftUI content) survives a close.
    private var mainWindow: NSWindow?

    /// Windows we've already decided are duplicates, so repeated `register`
    /// callbacks (SwiftUI calls it on every update) don't try to close twice.
    private var discarded = Set<ObjectIdentifier>()

    /// When true, the first window registered at launch is hidden immediately.
    /// Used for menu-bar-only / login launches so the window never flashes.
    var pendingInitialHide = false

    func register(_ window: NSWindow) {
        // Already the canonical window — just (re)apply any pending hide.
        if mainWindow === window {
            applyPendingHideIfNeeded(to: window)
            return
        }
        // A *different* window while we already have one is a duplicate — this
        // happens when macOS window-state restoration races SwiftUI's
        // `WindowGroup` on relaunch and both create a window. Keep exactly one
        // main window and quietly close the extra. (Detached terminal windows
        // never reach here; only the main `ContentView` hosts `WindowAccessor`.)
        if let existing = mainWindow, existing !== window {
            let key = ObjectIdentifier(window)
            guard !discarded.contains(key) else { return }
            discarded.insert(key)
            DispatchQueue.main.async { [weak window] in
                window?.close()
            }
            return
        }
        // First window — adopt it as the main window.
        window.isReleasedWhenClosed = false
        // Don't let AppKit restore this window on the next launch; SwiftUI's
        // `WindowGroup` already recreates it, and two sources = two windows.
        window.isRestorable = false
        mainWindow = window
        applyPendingHideIfNeeded(to: window)
    }

    private func applyPendingHideIfNeeded(to window: NSWindow) {
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
