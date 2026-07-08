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

    /// Whether this terminal is the one currently on screen and should accept
    /// file drops. Driven by `TerminalViewRepresentable` from the tab's
    /// visibility. Every tab stays mounted (to keep tunnels alive), so if all of
    /// them registered as drag destinations, a hidden tab stacked on top of the
    /// visible one would intercept the drop — registering only the visible
    /// terminal is what makes the path/contents popup reliably appear.
    var acceptsFileDrops = false {
        didSet {
            guard acceptsFileDrops != oldValue else { return }
            if acceptsFileDrops {
                // Append rather than replace so any of SwiftTerm's own drag
                // handling keeps working.
                registerForDraggedTypes(registeredDraggedTypes + [.fileURL])
            } else {
                unregisterDraggedTypes()
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            onAttachedToWindow?()
        }
    }

    // MARK: - File drop → paste path or contents
    //
    // Handled here in AppKit (a SwiftUI `.onDrop` never receives the drop — the
    // terminal's NSView sits on top and AppKit resolves the drag to it first).
    // Only the visible terminal is a registered destination (see
    // `acceptsFileDrops`), so the drop always lands on the tab on screen.

    /// The files from the most recent drop, awaiting the user's menu choice.
    private var pendingDropURLs: [URL] = []

    /// Combined text larger than this prompts a confirmation before pasting, so a
    /// stray drop of a huge file can't silently flood the terminal.
    private static let largeContentsPasteThreshold = 100 * 1024

    /// File URLs on the drag pasteboard, if any. Tries file-URL-only first, then
    /// falls back to reading any URLs and keeping the file ones — some drag
    /// sources (e.g. the in-app Finder tab) don't advertise the file-URL-only
    /// flag the stricter read requires.
    private func droppedFileURLs(_ sender: NSDraggingInfo) -> [URL] {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let files = urls.filter(\.isFileURL)
            if !files.isEmpty { return files }
        }
        return []
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

    /// Copy the selection, sanitized so ANSI colour / control sequences never
    /// reach the clipboard. SwiftTerm's own copy reads the character stored in
    /// each cell, so an ordinary selection is already plain text and the strip is
    /// a harmless no-op — this defends against escape bytes that end up in the
    /// buffer as literal characters (output that force-emits colour codes, a
    /// `cat` of a file with embedded escapes, …), which otherwise paste elsewhere
    /// as unreadable "␛[0m" gibberish. Overriding `copy(_:)` covers every copy
    /// path: ⌘C, the right-click Copy item, and smart copy-on-right-click all
    /// funnel through here.
    @objc override func copy(_ sender: Any) {
        super.copy(sender)     // let SwiftTerm put the selected text on the pasteboard
        let pb = NSPasteboard.general
        guard let raw = pb.string(forType: .string) else { return }
        let clean = HistoryTerminalView.strippingANSISequences(raw)
        if clean != raw {
            pb.clearContents()
            pb.setString(clean, forType: .string)
        }
    }

    /// Remove ANSI/CSI/OSC escape sequences and stray C0 control bytes from text,
    /// keeping printable characters plus tab, newline and carriage return so
    /// copied multi-line / tabular output stays intact.
    static func strippingANSISequences(_ s: String) -> String {
        // Fast path: nothing to strip when there's no ESC and no other control
        // byte beyond the whitespace we keep.
        if !s.unicodeScalars.contains(where: { $0.value == 0x1b
            || ($0.value < 0x20 && $0.value != 0x09 && $0.value != 0x0a && $0.value != 0x0d)
            || $0.value == 0x7f }) {
            return s
        }
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count)
        var i = 0
        while i < scalars.count {
            let u = scalars[i].value
            if u == 0x1b {                       // ESC — start of an escape sequence
                i += 1
                guard i < scalars.count else { break }
                let next = scalars[i].value
                if next == 0x5b {                // '[' → CSI: params… then a final @–~
                    i += 1
                    while i < scalars.count, !(0x40...0x7e).contains(scalars[i].value) { i += 1 }
                    if i < scalars.count { i += 1 }
                } else if next == 0x5d {         // ']' → OSC: … ended by BEL or ESC '\'
                    i += 1
                    while i < scalars.count, scalars[i].value != 0x07, scalars[i].value != 0x1b { i += 1 }
                    if i < scalars.count, scalars[i].value == 0x1b { i += 1 }
                    if i < scalars.count { i += 1 }
                } else {
                    i += 1                       // a two-character ESC sequence
                }
                continue
            }
            if u < 0x20, u != 0x09, u != 0x0a, u != 0x0d {   // drop C0 except TAB/NL/CR
                i += 1
                continue
            }
            if u == 0x7f {                       // drop DEL
                i += 1
                continue
            }
            out.append(scalars[i])
            i += 1
        }
        return String(out)
    }
}
