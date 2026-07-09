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

    // MARK: Sheet frame stability
    //
    // Presenting or dismissing a sheet on a `.unified`-toolbar window lets AppKit
    // re-measure the titlebar/toolbar and nudge the whole window down a few
    // points — visible on both Save and Cancel of the profile editor. A one-shot
    // restore *after* the move has already painted just produces a visible
    // shift-then-snap-back bounce. Instead we hold the window at its pre-sheet
    // frame for the length of the transition, correcting *synchronously* the
    // instant AppKit moves or resizes it (via the window's own notifications), so
    // the shifted position never reaches the screen.

    /// The main window's frame captured just before a modal sheet is shown.
    private var lockedFrame: NSRect?
    /// Active observers holding the window still during a sheet transition.
    private var frameGuardObservers: [NSObjectProtocol] = []
    /// Fires when the guard period ends.
    private var frameGuardTimer: Timer?

    /// Snapshot the main window's frame before a sheet (e.g. the profile editor)
    /// is presented, so `beginFrameGuard()` can hold it there on dismiss.
    func rememberFrame() {
        lockedFrame = mainWindow?.frame
    }

    /// Actively hold the window at the remembered frame for a short period,
    /// restoring it the instant AppKit tries to move or resize it. This absorbs
    /// the unified-toolbar re-measure that otherwise drifts the window on sheet
    /// dismiss, without the visible bounce a delayed one-shot restore caused.
    func beginFrameGuard(duration: TimeInterval = 0.8) {
        guard let window = mainWindow, lockedFrame != nil else { return }
        // Correct immediately, then on every move/resize for the guard period.
        holdFrame(window)
        endFrameGuard(clearFrame: false)   // tear down any prior guard, keep frame
        let restore: (Notification) -> Void = { [weak self, weak window] _ in
            guard let self, let window else { return }
            self.holdFrame(window)
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main, using: restore)
            frameGuardObservers.append(token)
        }
        frameGuardTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.endFrameGuard(clearFrame: true)
        }
    }

    /// Snap the window back to the locked frame if it has drifted. The guard
    /// (`window.frame != target`) both avoids needless work and stops the
    /// `setFrame`-triggered notification from recursing.
    private func holdFrame(_ window: NSWindow) {
        guard let target = lockedFrame, window.frame != target else { return }
        window.setFrame(target, display: true)
    }

    /// Stop guarding. `clearFrame` also forgets the remembered frame (done when
    /// the transition is fully over).
    private func endFrameGuard(clearFrame: Bool) {
        frameGuardTimer?.invalidate()
        frameGuardTimer = nil
        for token in frameGuardObservers {
            NotificationCenter.default.removeObserver(token)
        }
        frameGuardObservers.removeAll()
        if clearFrame { lockedFrame = nil }
    }
}
