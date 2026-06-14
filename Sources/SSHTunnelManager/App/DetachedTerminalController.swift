import AppKit
import SwiftUI
import Combine

/// Per-detached-window state, shared with its SwiftUI toolbar.
final class DetachedWindowModel: ObservableObject {
    let session: TerminalSession
    @Published var alwaysOnTop: Bool = false
    /// Called when the pin is toggled (the controller wires this to window.level).
    var onSetAlwaysOnTop: (Bool) -> Void = { _ in }
    /// Called by the "re-attach" button (the controller wires this to close()).
    var onReattach: () -> Void = {}

    init(session: TerminalSession) { self.session = session }
}

/// Manages floating windows that host *detached* terminal tabs.
///
/// A terminal's `NSView` lives on its `TerminalSession`, so the very same running
/// session can be re-parented from the main window's tab area into its own window
/// (and back) without disturbing the process or its tunnels. Detaching only moves
/// where the view is shown; closing the floating window re-attaches the tab.
final class DetachedTerminalController: NSObject, NSWindowDelegate {
    static let shared = DetachedTerminalController()

    private let manager = TerminalSessionManager.shared
    private let store = ProfileStore.shared
    private var windows: [UUID: NSWindow] = [:]
    private var titleObservers: [UUID: AnyCancellable] = [:]
    private var sessionsObserver: AnyCancellable?
    private var cascadePoint = NSPoint(x: 140, y: 140)

    private override init() {
        super.init()
        // If a detached session is closed/killed elsewhere (e.g. "Disconnect All
        // Tunnels" or its own exit banner), close its floating window too.
        sessionsObserver = manager.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] live in
                guard let self else { return }
                let liveIDs = Set(live.map { $0.id })
                for (id, window) in self.windows where !liveIDs.contains(id) {
                    window.close()
                }
            }
    }

    /// Whether the given session is currently in its own window.
    func isDetached(_ session: TerminalSession) -> Bool {
        windows[session.id] != nil
    }

    /// Move a tab into its own floating window (or focus it if already detached).
    func detach(_ session: TerminalSession) {
        if let existing = windows[session.id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // Release the terminal from the main window's tab area first, so the view
        // is cleanly re-parented into the floating window below.
        manager.markDetached(session)

        let model = DetachedWindowModel(session: session)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = session.title
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed          // never merge into the main window's tabs
        window.minSize = NSSize(width: 420, height: 240)
        window.delegate = self

        model.onSetAlwaysOnTop = { [weak window] on in
            window?.level = on ? .floating : .normal
        }
        model.onReattach = { [weak window] in window?.close() }

        let root = DetachedTerminalView(model: model)
            .environmentObject(manager)
            .environmentObject(store)
        window.contentViewController = NSHostingController(rootView: root)

        cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        windows[session.id] = window
        // Keep the window's titlebar in sync with the live session title.
        titleObservers[session.id] = session.$title
            .receive(on: RunLoop.main)
            .sink { [weak window] title in window?.title = title }
    }

    /// Bring a session back into the main window's tab bar.
    func reattach(_ session: TerminalSession) {
        windows[session.id]?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        windows[id] = nil
        titleObservers[id] = nil
        // If the session is still alive, closing its window means "re-attach" it;
        // if it's already gone (killed elsewhere) there's nothing to bring back.
        if let session = manager.sessions.first(where: { $0.id == id }) {
            manager.markAttached(session)
            WindowManager.shared.showMainWindow()
        }
    }
}
