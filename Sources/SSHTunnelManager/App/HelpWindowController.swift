import AppKit
import SwiftUI

/// Hosts the Help window (a SwiftUI `HelpView`) in a single reusable AppKit
/// window, so it can be opened from the Help menu and brought forward again
/// without spawning duplicates. Mirrors the app's other AppKit-hosted windows.
final class HelpWindowController: NSObject, NSWindowDelegate {
    static let shared = HelpWindowController()
    private override init() {}

    private var window: NSWindow?

    /// Show the Help window, optionally jumping to a specific section.
    func show(_ selection: HelpSelection = .article("getting-started")) {
        // Rebuild the content so the initial selection is honored each time.
        let hosting = NSHostingController(rootView: HelpView(initial: selection))

        if let window {
            window.contentViewController = hosting
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(contentViewController: hosting)
        window.title = "SSH Tunnel Manager Help"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 860, height: 600))
        window.minSize = NSSize(width: 760, height: 520)
        window.center()
        window.delegate = self
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
