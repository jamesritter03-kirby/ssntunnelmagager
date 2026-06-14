import AppKit
import SwiftTerm

/// A `LocalProcessTerminalView` that taps the bytes flowing to and from the
/// shell, without altering normal behaviour.
///
/// * `onUserInput` fires with every slice the user/view sends to the process
///   (used to reconstruct typed command lines for the history).
/// * `onProcessOutput` fires with every slice received from the process
///   (used to detect password prompts so secrets are never recorded).
///
/// Both hooks call `super`, so the terminal still works exactly as before.
final class HistoryTerminalView: LocalProcessTerminalView {
    var onUserInput: ((ArraySlice<UInt8>) -> Void)?
    var onProcessOutput: ((ArraySlice<UInt8>) -> Void)?

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onUserInput?(data)
        super.send(source: source, data: data)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onProcessOutput?(slice)
        super.dataReceived(slice: slice)
    }

    /// Right-click pastes the clipboard (like PuTTY and most terminals).
    ///
    /// If a full-screen app has turned on mouse reporting (vim, htop, tmux, …)
    /// we defer to the default handling so the app still receives the click.
    override func rightMouseDown(with event: NSEvent) {
        if let terminal, case .off = terminal.mouseMode {
            paste(self)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}
