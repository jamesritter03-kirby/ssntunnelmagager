import SwiftUI
import SwiftTerm

/// Bridges a session's `LocalProcessTerminalView` (AppKit) into SwiftUI.
///
/// The view is owned by the `TerminalSession`, so SwiftUI re-renders never destroy
/// the running process — important for keeping tunnels alive while switching tabs.
struct TerminalViewRepresentable: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> HistoryTerminalView {
        session.terminalView
    }

    func updateNSView(_ nsView: HistoryTerminalView, context: Context) {
        // Nothing to update; the session owns and configures the view.
    }
}
