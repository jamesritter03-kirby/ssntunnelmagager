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
    /// Fires after Auto Layout sizes the view. PTY-backed sessions also wait for a
    /// real (non-placeholder) size before spawning — a freshly-created workspace
    /// can mount the view in its window a beat before layout gives it real bounds.
    var onLayout: (() -> Void)?

    /// Whether we've registered for file drops yet (done once, lazily).
    private var didRegisterDragTypes = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            if !didRegisterDragTypes {
                didRegisterDragTypes = true
                // Accept file drops so dragging a file in offers to paste its
                // path or its contents. Append rather than replace so SwiftTerm's
                // own drag handling (text drops) keeps working.
                registerForDraggedTypes(registeredDraggedTypes + [.fileURL])
            }
            onAttachedToWindow?()
        }
    }

    // MARK: - File drop → paste path or contents

    /// The files from the most recent drop, awaiting the user's menu choice.
    private var pendingDropURLs: [URL] = []

    /// Combined text larger than this prompts a confirmation before pasting, so a
    /// stray drop of a huge file can't silently flood the terminal.
    private static let largeContentsPasteThreshold = 100 * 1024

    /// File URLs on the drag pasteboard, if any.
    private func droppedFileURLs(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        droppedFileURLs(sender).isEmpty ? super.prepareForDragOperation(sender) : true
    }

    /// Drop one or more files to insert either their shell-quoted **paths** or
    /// their **text contents** at the prompt — a small menu pops up at the drop
    /// point so the user picks. (A plain text drag still falls through to
    /// SwiftTerm's own handling.)
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFileURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        // Convert the drop location into this view's coordinates, then present the
        // choice on the next runloop tick so the drag session fully concludes
        // before the (modal) popup menu tracks the mouse.
        let dropPoint = convert(sender.draggingLocation, from: nil)
        DispatchQueue.main.async { [weak self] in
            self?.presentDropChoice(for: urls, at: dropPoint)
        }
        return true
    }

    /// Pop up a Paste Path / Paste Contents / Cancel menu at the drop point.
    private func presentDropChoice(for urls: [URL], at point: NSPoint) {
        pendingDropURLs = urls
        let fileCount = regularFiles(in: urls).count

        let menu = NSMenu()
        menu.autoenablesItems = false

        let pathItem = menu.addItem(
            withTitle: urls.count > 1 ? "Paste \(urls.count) Paths" : "Paste Path",
            action: #selector(dropPastePath), keyEquivalent: "")
        pathItem.target = self

        let contentsItem = menu.addItem(
            withTitle: fileCount > 1 ? "Paste Contents of \(fileCount) Files" : "Paste Contents",
            action: #selector(dropPasteContents), keyEquivalent: "")
        contentsItem.target = self
        contentsItem.isEnabled = fileCount > 0     // directories have no “contents”

        menu.addItem(.separator())
        menu.addItem(withTitle: "Cancel", action: nil, keyEquivalent: "")

        menu.popUp(positioning: pathItem, at: point, in: self)
    }

    /// The regular (non-directory) files among a set of dropped URLs.
    private func regularFiles(in urls: [URL]) -> [URL] {
        urls.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                && !isDir.boolValue
        }
    }

    /// Insert the dropped files' shell-quoted paths, space-separated with a
    /// trailing space — the classic Terminal.app behaviour.
    @objc private func dropPastePath() {
        let urls = pendingDropURLs
        pendingDropURLs = []
        guard !urls.isEmpty else { return }
        send(txt: urls.map { SSHCommandBuilder.shellQuote($0.path) }.joined(separator: " ") + " ")
    }

    /// Insert the dropped files' text contents at the prompt. Binary files are
    /// skipped (with a fallback to pasting their path); a very large paste is
    /// confirmed first.
    @objc private func dropPasteContents() {
        let urls = pendingDropURLs
        pendingDropURLs = []
        let files = regularFiles(in: urls)
        guard !files.isEmpty else { return }

        var pieces: [String] = []
        var skipped: [URL] = []
        for url in files {
            if let text = HistoryTerminalView.readTextContents(of: url) { pieces.append(text) }
            else { skipped.append(url) }
        }

        // Nothing decoded as text — offer to paste the path(s) instead.
        guard !pieces.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = skipped.count == 1
                ? "“\(skipped[0].lastPathComponent)” doesn’t look like a text file"
                : "Those files don’t look like text"
            alert.informativeText = "Their contents can’t be pasted as text. Paste the file path instead?"
            alert.addButton(withTitle: "Paste Path")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                send(txt: files.map { SSHCommandBuilder.shellQuote($0.path) }.joined(separator: " ") + " ")
            }
            return
        }

        let combined = pieces.joined(separator: "\n")

        // Guard against accidentally flooding the terminal with a huge file.
        if combined.utf8.count > HistoryTerminalView.largeContentsPasteThreshold {
            let size = ByteCountFormatter.string(fromByteCount: Int64(combined.utf8.count),
                                                 countStyle: .file)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Paste \(size) into the terminal?"
            alert.informativeText = "The file contents will be sent as if typed — any line breaks may run as commands."
            alert.addButton(withTitle: "Paste")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        send(txt: combined)

        // Note any files that were skipped because they weren't text.
        if !skipped.isEmpty {
            let names = skipped.map(\.lastPathComponent).joined(separator: ", ")
            let note = NSAlert()
            note.messageText = "Skipped \(skipped.count) non-text file\(skipped.count == 1 ? "" : "s")"
            note.informativeText = "Only text files were pasted. Skipped: \(names)"
            note.addButton(withTitle: "OK")
            note.runModal()
        }
    }

    /// Read a file as text, trying common encodings; nil if it looks binary.
    private static func readTextContents(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.isEmpty { return "" }
        // A NUL byte near the start is a strong signal the file is binary.
        if data.prefix(4096).contains(0) { return nil }
        for enc: String.Encoding in [.utf8, .isoLatin1, .windowsCP1252, .macOSRoman] {
            if var s = String(data: data, encoding: enc) {
                if s.first == "\u{FEFF}" { s.removeFirst() }   // strip a leading BOM
                return s
            }
        }
        return nil
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onLayout?()
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
