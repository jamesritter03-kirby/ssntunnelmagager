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

    /// Interpret a right-click according to the user's chosen behavior.
    ///
    /// If a full-screen app has turned on mouse reporting (vim, htop, tmux, …) we
    /// always defer to the default handling so the app still receives the click.
    /// Otherwise we apply the configured strategy. The "smart" mode is modelled on
    /// RightClickPasteKing's Windows/Linux behavior — copy a selection, else paste,
    /// else show a menu — but because we own this terminal view we can read the
    /// selection directly (`selectionActive`) instead of probing for it with a
    /// synthesized ⌘C and the pasteboard change count.
    override func rightMouseDown(with event: NSEvent) {
        guard let terminal, case .off = terminal.mouseMode else {
            super.rightMouseDown(with: event)
            return
        }
        switch AppSettings.shared.terminalRightClick {
        case .paste:
            paste(self)
        case .smartCopyPaste:
            smartRightClick(with: event)
        case .contextMenu:
            showContextMenu(for: event)
        }
    }

    /// Windows/Linux-style right-click: copy the selection if there is one
    /// (optionally clearing it so the next click pastes), otherwise paste the
    /// clipboard, otherwise show the context menu so the click is never wasted.
    private func smartRightClick(with event: NSEvent) {
        if selectionActive {
            copy(self)
            if AppSettings.shared.deselectTerminalAfterCopy { selectNone() }
            return
        }
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            paste(self)
            return
        }
        showContextMenu(for: event)
    }

    /// Pop up a small Copy / Paste / Select All menu at the click location. Items
    /// are enabled to match the current state (Copy only with a selection, Paste
    /// only with clipboard text), so the menu is never misleading.
    private func showContextMenu(for event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let copyItem = menu.addItem(withTitle: "Copy",
                                    action: #selector(contextCopy), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = selectionActive

        let pasteItem = menu.addItem(withTitle: "Paste",
                                     action: #selector(contextPaste), keyEquivalent: "")
        pasteItem.target = self
        pasteItem.isEnabled = NSPasteboard.general.string(forType: .string)?.isEmpty == false

        menu.addItem(.separator())
        let selectAllItem = menu.addItem(withTitle: "Select All",
                                         action: #selector(contextSelectAll), keyEquivalent: "")
        selectAllItem.target = self

        menu.popUp(positioning: nil,
                   at: convert(event.locationInWindow, from: nil), in: self)
    }

    @objc private func contextCopy() { copy(self) }
    @objc private func contextPaste() { paste(self) }
    @objc private func contextSelectAll() { selectAll(self) }
}
