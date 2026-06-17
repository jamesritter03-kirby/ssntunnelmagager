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
    /// Text-size zoom requested via the keyboard (⌘+ / ⌘− / ⌘0).
    enum Zoom { case increase, decrease, reset }

    var onUserInput: ((ArraySlice<UInt8>) -> Void)?
    var onProcessOutput: ((ArraySlice<UInt8>) -> Void)?
    /// Called for ⌘+ / ⌘− / ⌘0 while this terminal is focused.
    var onZoom: ((Zoom) -> Void)?
    /// Fires when the view becomes part of a window. PTY-backed sessions wait for
    /// this before spawning, so the process starts against a real on-screen size
    /// (e.g. when restoring a saved session before the window is shown).
    var onAttachedToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onAttachedToWindow?() }
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onUserInput?(data)
        super.send(source: source, data: data)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onProcessOutput?(slice)
        super.dataReceived(slice: slice)
    }

    /// Handle ⌘+ / ⌘= (bigger), ⌘− / ⌘_ (smaller) and ⌘0 (reset) to zoom the
    /// terminal text. We only act when THIS terminal is the window's first
    /// responder, so background tabs (all kept mounted) are unaffected, and we
    /// run before the menu so the focused terminal — including a detached
    /// window — always wins. Everything else defers to the normal handling.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self,
           flags.contains(.command), !flags.contains(.option), !flags.contains(.control),
           let chars = event.charactersIgnoringModifiers {
            switch chars {
            case "+", "=": onZoom?(.increase); return true
            case "-", "_": onZoom?(.decrease); return true
            case "0":      onZoom?(.reset);    return true
            default:       break
            }
        }
        return super.performKeyEquivalent(with: event)
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
