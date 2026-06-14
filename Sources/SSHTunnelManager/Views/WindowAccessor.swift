import SwiftUI
import AppKit

/// Invisible helper that captures the hosting `NSWindow` and registers it with
/// `WindowManager`, so the menu bar item can re-show the window after a close.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                WindowManager.shared.register(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            WindowManager.shared.register(window)
        }
    }
}
