import SwiftUI
import SwiftTerm

/// Bridges a session's `LocalProcessTerminalView` (AppKit) into SwiftUI.
///
/// The view is owned by the `TerminalSession`, so SwiftUI re-renders never destroy
/// the running process — important for keeping tunnels alive while switching tabs.
struct TerminalViewRepresentable: NSViewRepresentable {
    let session: TerminalSession
    /// Whether this terminal is the one currently on screen. Only the visible
    /// terminal registers as a file-drop destination, so drops don't get
    /// intercepted by a mounted-but-hidden tab stacked on top of it.
    var isActive: Bool = true

    func makeNSView(context: Context) -> HistoryTerminalView {
        session.terminalView
    }

    func updateNSView(_ nsView: HistoryTerminalView, context: Context) {
        nsView.acceptsFileDrops = isActive
    }
}
