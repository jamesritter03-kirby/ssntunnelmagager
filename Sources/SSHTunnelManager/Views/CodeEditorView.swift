import SwiftUI
import AppKit

// MARK: - Code text view

/// The document `NSTextView`. It reserves a strip on its left for the line‑number
/// gutter by shifting its text container to the right; the numbers themselves are
/// painted by a separate `GutterView` pinned over that strip. (Drawing the gutter
/// inside the text view — or via `NSRulerView` — mis‑behaves when the view is
/// hosted in SwiftUI: the earlier ruler was laid over the text, hiding it.)
final class CodeTextView: NSTextView {
    var showsLineNumbers = true { didSet { refreshGutter() } }
    var gutterFont: NSFont = .monospacedDigitSystemFont(ofSize: 10, weight: .regular) {
        didSet { refreshGutter() }
    }
    /// The document's logical line count, driving the gutter width.
    var displayLineCount = 1 { didSet { if displayLineCount != oldValue { refreshGutter() } } }

    /// Notified when the reserved gutter width changes (so the coordinator can
    /// resize the companion `GutterView`).
    var onGutterWidthChange: (() -> Void)?

    /// Called with a file dropped onto the editor, so the model can offer to open
    /// it (Notepad++‑style). Set by the coordinator; see the drag overrides below.
    var onFileDropped: ((URL) -> Void)?

    let gutterSidePadding: CGFloat = 7

    /// The width reserved for the gutter (0 when line numbers are hidden).
    var gutterWidth: CGFloat {
        guard showsLineNumbers else { return 0 }
        let digits = max(2, String(max(1, displayLineCount)).count)
        let sample = String(repeating: "8", count: digits) as NSString
        return ceil(sample.size(withAttributes: [.font: gutterFont]).width) + gutterSidePadding * 2
    }

    /// Shift the text to the right of the gutter.
    override var textContainerOrigin: NSPoint {
        let base = super.textContainerOrigin
        return NSPoint(x: base.x + gutterWidth, y: base.y)
    }

    private func refreshGutter() {
        invalidateTextContainerOrigin()
        needsDisplay = true
        onGutterWidthChange?()
    }

    // MARK: Drag‑to‑open

    /// The regular (non‑directory) file URLs currently being dragged, if any.
    private static func droppableFileURLs(_ sender: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: opts) as? [URL] ?? []
        return urls.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.droppableFileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.droppableFileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Self.droppableFileURLs(sender).isEmpty ? super.prepareForDragOperation(sender) : true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Intercept a dropped file to *open* it, rather than let the text view
        // insert its path as text. Defer so the drag session finishes first.
        guard let first = Self.droppableFileURLs(sender).first else {
            return super.performDragOperation(sender)
        }
        let handler = onFileDropped
        DispatchQueue.main.async { handler?(first) }
        return true
    }
}

// MARK: - Line‑number gutter

/// A slim view pinned over the left edge of the scroll view that paints logical
/// line numbers aligned with the text view's line fragments. It is a sibling of
/// the clip view (not the scrolling document), so it stays put while the text
/// scrolls; on each draw it reads the text view's visible rect to place numbers.
final class GutterView: NSView {
    weak var textView: CodeTextView?
    var backgroundColor: NSColor = .textBackgroundColor { didSet { needsDisplay = true } }
    var textColor: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    var separatorColor: NSColor = .separatorColor { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()
        separatorColor.setStroke()
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        sep.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        sep.lineWidth = 1
        sep.stroke()

        guard let textView, textView.showsLineNumbers,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let content = textView.string as NSString
        let visibleRect = textView.visibleRect
        let originY = textView.textContainerOrigin.y
        let padding = textView.gutterSidePadding
        let attrs: [NSAttributedString.Key: Any] = [
            .font: textView.gutterFont, .foregroundColor: textColor
        ]

        func drawNumber(_ n: Int, fragmentMinY: CGFloat, fragmentHeight: CGFloat) {
            let s = "\(n)" as NSString
            let size = s.size(withAttributes: attrs)
            // Text‑view Y of the fragment → gutter Y by removing the scroll offset.
            let y = (fragmentMinY + originY) - visibleRect.minY + (fragmentHeight - size.height) / 2
            let x = bounds.width - size.width - padding
            s.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }

        // Which characters are visible right now.
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        var charIndex = content.lineRange(
            for: NSRange(location: min(charRange.location, content.length), length: 0)).location
        var lineNumber = 1 + numberOfNewlines(in: content, upTo: charIndex)
        let end = NSMaxRange(charRange)

        while charIndex < content.length && charIndex <= end {
            let lineRange = content.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            var effective = NSRange()
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex,
                                                          effectiveRange: &effective,
                                                          withoutAdditionalLayout: false)
            drawNumber(lineNumber, fragmentMinY: fragment.minY, fragmentHeight: fragment.height)
            lineNumber += 1
            let next = NSMaxRange(lineRange)
            if next <= charIndex { break }
            charIndex = next
        }

        // The trailing empty line (empty document, or a file ending in newline).
        if content.length == 0 || content.hasSuffix("\n") {
            let extra = layoutManager.extraLineFragmentRect
            if extra.height > 0 {
                drawNumber(lineNumber, fragmentMinY: extra.minY, fragmentHeight: extra.height)
            }
        }
    }

    private func numberOfNewlines(in text: NSString, upTo location: Int) -> Int {
        var count = 0
        var searchRange = NSRange(location: 0, length: min(location, text.length))
        while searchRange.length > 0 {
            let r = text.range(of: "\n", options: [.literal], range: searchRange)
            if r.location == NSNotFound { break }
            count += 1
            let next = r.location + 1
            searchRange = NSRange(location: next, length: max(0, min(location, text.length) - next))
        }
        return count
    }
}

// MARK: - Editor representable

/// A Notepad++‑style code editor built on `NSTextView`: monospaced, undoable,
/// with a line‑number gutter, syntax highlighting, optional soft‑wrap and
/// live‑adjustable font size. Editing state flows back through `TextEditorModel`.
struct CodeEditorView: NSViewRepresentable {
    @ObservedObject var model: TextEditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        let contentSize = scrollView.contentSize
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: contentSize.width,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = CodeTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: container)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .controlAccentColor
        textView.usesFindBar = false
        textView.showsLineNumbers = model.showLineNumbers

        // Accept a dragged file so it can be opened (in addition to the text
        // view's own drag types), routed to the model's confirm‑and‑open flow.
        textView.registerForDraggedTypes(textView.registeredDraggedTypes + [.fileURL])
        textView.onFileDropped = { [weak model = self.model] url in
            model?.openDroppedFile(url)
        }

        textView.delegate = context.coordinator
        textStorage.delegate = context.coordinator

        scrollView.documentView = textView

        // The line‑number gutter floats over the left edge of the scroll view
        // (a sibling of the clip view, so it doesn't scroll away).
        let gutter = GutterView(frame: NSRect(x: 0, y: 0, width: 0, height: contentSize.height))
        gutter.textView = textView
        gutter.autoresizingMask = [.height]
        scrollView.addSubview(gutter)

        context.coordinator.attach(textView: textView, scrollView: scrollView, gutter: gutter)
        model.engine.textView = textView

        // Initial content + styling.
        context.coordinator.applyTheme()
        context.coordinator.reload(force: true)
        context.coordinator.applyFont()
        context.coordinator.applyWrap()
        context.coordinator.applyLineNumbers()

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.sync()
    }

    /// Pin the scroll view to the size SwiftUI proposes. Without this, an
    /// `NSScrollView` whose document `NSTextView` is horizontally resizable
    /// reports its (huge) document width as its fitting size, so in the tabbed
    /// layout — where every tab is overlaid in a `ZStack` that grows to its
    /// largest child — the editor balloons past the window and hides the tab
    /// bar and the text being typed. Returning the proposed size keeps the
    /// editor inside its tab; the text scrolls within these bounds instead.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView,
                      context: Context) -> CGSize? {
        let resolved = proposal.replacingUnspecifiedDimensions(
            by: CGSize(width: 480, height: 320))
        let width = resolved.width.isFinite ? resolved.width : 480
        let height = resolved.height.isFinite ? resolved.height : 320
        return CGSize(width: width, height: height)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        let model: TextEditorModel
        private weak var textView: CodeTextView?
        private weak var scrollView: NSScrollView?
        private weak var gutter: GutterView?

        private var lastReloadToken: UUID?
        private var appliedLanguage: CodeLanguage?
        private var appliedFontSize: Double = 0
        private var appliedWrap: Bool?
        private var appliedLineNumbers: Bool?
        private var appliedThemeID: String?

        private var fullHighlightScheduled = false
        private var boundsObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?

        init(model: TextEditorModel) {
            self.model = model
            super.init()
        }

        deinit {
            if let o = boundsObserver { NotificationCenter.default.removeObserver(o) }
            if let o = frameObserver { NotificationCenter.default.removeObserver(o) }
        }

        func attach(textView: CodeTextView, scrollView: NSScrollView, gutter: GutterView) {
            self.textView = textView
            self.scrollView = scrollView
            self.gutter = gutter
            textView.onGutterWidthChange = { [weak self] in self?.positionGutter() }
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.contentView.postsFrameChangedNotifications = true
            // On scroll, redraw the gutter so its numbers track the text.
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView, queue: .main) { [weak self] _ in
                self?.gutter?.needsDisplay = true
            }
            // When the scroll view resizes (SwiftUI relayout, window resize,
            // wrap toggle), re-fit the document text view so it fills the
            // visible area — otherwise a horizontally-resizable text view stays
            // at its (near-zero) content width and typed text is invisible.
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView.contentView, queue: .main) { [weak self] _ in
                self?.layoutTextView()
                self?.positionGutter()
            }
        }

        /// Size the gutter to the current reserved width and clip‑view height,
        /// pinned to the left edge, and redraw it. Hidden when line numbers are off.
        func positionGutter() {
            guard let textView, let scrollView, let gutter else { return }
            let clip = scrollView.contentView.frame
            let width = textView.gutterWidth
            gutter.isHidden = !textView.showsLineNumbers || width <= 0
            gutter.frame = NSRect(x: clip.minX, y: clip.minY, width: width, height: clip.height)
            gutter.needsDisplay = true
        }

        /// Keep the document `NSTextView` at least as large as the visible area.
        /// With word-wrap off the text view is horizontally resizable, which
        /// disables width autoresizing; created inside a zero-sized scroll view
        /// (SwiftUI lays the representable out after `makeNSView`), it would
        /// otherwise collapse to ~0 width and show nothing. In wrap mode the
        /// width simply tracks the visible width.
        func layoutTextView() {
            guard let textView, let scrollView, let container = textView.textContainer else { return }
            let content = scrollView.contentSize
            guard content.width > 1, content.height > 1 else { return }
            let inset = textView.textContainerInset
            let gutter = textView.gutterWidth
            if model.wordWrap {
                container.containerSize = NSSize(width: max(content.width - inset.width * 2 - gutter, 1),
                                                 height: CGFloat.greatestFiniteMagnitude)
                if abs(textView.frame.width - content.width) > 0.5 {
                    textView.setFrameSize(NSSize(width: content.width,
                                                 height: max(textView.frame.height, content.height)))
                }
            } else {
                textView.layoutManager?.ensureLayout(for: container)
                let used = textView.layoutManager?.usedRect(for: container).size ?? .zero
                let targetWidth = max(content.width, used.width + inset.width * 2 + gutter)
                let targetHeight = max(content.height, used.height + inset.height * 2)
                if abs(textView.frame.width - targetWidth) > 0.5 ||
                    textView.frame.height < targetHeight - 0.5 {
                    textView.setFrameSize(NSSize(width: targetWidth, height: targetHeight))
                }
            }
        }

        // Editor font.
        private var font: NSFont {
            CodeEditorView.editorFont(model.fontSize)
        }

        private func baseAttributes(_ font: NSFont) -> [NSAttributedString.Key: Any] {
            let para = NSMutableParagraphStyle()
            let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
            para.defaultTabInterval = max(charWidth * 4, 8)
            para.tabStops = []
            return [.font: font, .foregroundColor: theme.foreground, .paragraphStyle: para]
        }

        // MARK: Apply model → view

        /// Reconcile every editor property that may have changed on the model.
        func sync() {
            if appliedThemeID != model.themeID { applyTheme() }
            if lastReloadToken != model.reloadToken { reload(force: false) }
            if appliedFontSize != model.fontSize { applyFont() }
            if appliedLanguage != model.language { applyLanguage() }
            if appliedWrap != model.wordWrap { applyWrap() }
            if appliedLineNumbers != model.showLineNumbers { applyLineNumbers() }
            layoutTextView()
            positionGutter()
        }

        // The active theme.
        private var theme: EditorTheme { EditorTheme.theme(id: model.themeID) }

        /// Paint the editor with the current theme: explicit background and
        /// foreground colours (so text is never drawn invisibly against its own
        /// background), caret / selection colours, a matching view appearance,
        /// and a re-highlight so token colours pick up the new palette.
        func applyTheme() {
            guard let textView, let scrollView else { return }
            appliedThemeID = model.themeID
            let t = theme
            textView.appearance = t.nsAppearance
            scrollView.appearance = t.nsAppearance
            scrollView.drawsBackground = true
            scrollView.backgroundColor = t.background
            textView.drawsBackground = true
            textView.backgroundColor = t.background
            textView.textColor = t.foreground
            textView.insertionPointColor = t.insertionPoint
            textView.selectedTextAttributes = [
                .backgroundColor: t.selection,
                .foregroundColor: t.foreground
            ]
            var typing = textView.typingAttributes
            typing[.foregroundColor] = t.foreground
            typing[.font] = font
            textView.typingAttributes = typing
            gutter?.backgroundColor = t.gutterBackground
            gutter?.textColor = t.gutterForeground
            gutter?.separatorColor = t.separator
            highlightAll()
            textView.needsDisplay = true
            gutter?.needsDisplay = true
        }

        /// Replace the buffer contents from the model (open / new / revert).
        func reload(force: Bool) {
            guard let textView, let storage = textView.textStorage else { return }
            lastReloadToken = model.reloadToken
            let attrs = baseAttributes(font)
            textView.typingAttributes = attrs
            storage.beginEditing()
            storage.setAttributedString(NSAttributedString(string: model.pendingContent, attributes: attrs))
            storage.endEditing()
            textView.undoManager?.removeAllActions()
            highlightAll()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            updateStatus()
            updateLineCount()
            layoutTextView()
            positionGutter()
            textView.needsDisplay = true
            appliedLanguage = model.language
        }

        func applyFont() {
            guard let textView, let storage = textView.textStorage else { return }
            appliedFontSize = model.fontSize
            let f = font
            textView.font = f
            var attrs = textView.typingAttributes
            attrs[.font] = f
            if let para = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                let charWidth = ("0" as NSString).size(withAttributes: [.font: f]).width
                para.defaultTabInterval = max(charWidth * 4, 8)
                attrs[.paragraphStyle] = para
            }
            textView.typingAttributes = attrs
            let full = NSRange(location: 0, length: storage.length)
            storage.addAttributes([.font: f], range: full)
            textView.gutterFont = .monospacedDigitSystemFont(ofSize: max(9, model.fontSize - 2), weight: .regular)
            highlightAll()
            layoutTextView()
            positionGutter()
            textView.needsDisplay = true
        }

        func applyLanguage() {
            appliedLanguage = model.language
            highlightAll()
        }

        func applyWrap() {
            guard let textView, let scrollView,
                  let container = textView.textContainer else { return }
            appliedWrap = model.wordWrap
            if model.wordWrap {
                let width = scrollView.contentSize.width
                container.widthTracksTextView = true
                container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
                textView.isHorizontallyResizable = false
                textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                textView.frame.size.width = width
                scrollView.hasHorizontalScroller = false
            } else {
                container.widthTracksTextView = false
                container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                textView.isHorizontallyResizable = true
                textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                scrollView.hasHorizontalScroller = true
            }
            layoutTextView()
            textView.needsDisplay = true
        }

        func applyLineNumbers() {
            appliedLineNumbers = model.showLineNumbers
            textView?.showsLineNumbers = model.showLineNumbers
            layoutTextView()
            positionGutter()
            textView?.needsDisplay = true
        }

        // MARK: Highlighting

        private func highlightAll() {
            guard let textView, let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            highlight(storage, range: full)
        }

        private func highlight(_ storage: NSTextStorage, range: NSRange) {
            guard range.length > 0 else { return }
            let f = font
            let t = theme
            storage.addAttributes([.font: f, .foregroundColor: t.foreground], range: range)
            guard model.language.hasHighlighting else { return }
            let text = storage.string
            for pattern in model.language.highlightPatterns() {
                pattern.regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                    guard let match else { return }
                    let r = pattern.group == 0 ? match.range : match.range(at: pattern.group)
                    guard r.location != NSNotFound, r.length > 0,
                          NSMaxRange(r) <= storage.length else { return }
                    storage.addAttribute(.foregroundColor,
                                         value: t.color(for: pattern.token), range: r)
                }
            }
        }

        /// Re‑highlight the whole document shortly after an edit so multi‑line
        /// constructs (block comments, triple‑quoted strings) stay correct,
        /// coalescing bursts of keystrokes. Skipped for very large files.
        private func scheduleFullHighlight() {
            guard !fullHighlightScheduled, let textView else { return }
            guard (textView.string as NSString).length <= 300_000 else { return }
            fullHighlightScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self else { return }
                self.fullHighlightScheduled = false
                self.highlightAll()
            }
        }

        // MARK: NSTextStorageDelegate

        func textStorage(_ textStorage: NSTextStorage,
                         didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange,
                         changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            guard model.language.hasHighlighting else { return }
            let ns = textStorage.string as NSString
            let safeLocation = min(editedRange.location, ns.length)
            let safeLength = min(editedRange.length, ns.length - safeLocation)
            let paragraph = ns.lineRange(for: NSRange(location: safeLocation, length: safeLength))
            highlight(textStorage, range: paragraph)
            scheduleFullHighlight()
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            model.markDirty()
            if let textView { model.captureLiveText(textView.string) }
            updateLineCount()
            updateStatus()
            layoutTextView()
            positionGutter()
            textView?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateStatus()
        }

        // MARK: Status bar

        private func updateStatus() {
            guard let textView else { return }
            let sel = textView.selectedRange()
            let full = textView.string as NSString
            let caret = min(sel.location, full.length)
            let head = full.substring(to: caret)
            let line = 1 + head.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            let column: Int
            if let nl = head.lastIndex(of: "\n") {
                column = head.distance(from: head.index(after: nl), to: head.endIndex) + 1
            } else {
                column = head.count + 1
            }
            model.caretLine = line
            model.caretColumn = column
            model.selectionLength = sel.length
        }

        private func updateLineCount() {
            guard let textView else { return }
            let s = textView.string
            model.characterCount = (s as NSString).length
            let count = 1 + s.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            model.lineCount = count
            textView.displayLineCount = count
        }
    }

    static func editorFont(_ size: Double) -> NSFont {
        let s = CGFloat(size)
        return NSFont(name: "SF Mono", size: s)
            ?? NSFont(name: "Menlo", size: s)
            ?? NSFont.monospacedSystemFont(ofSize: s, weight: .regular)
    }
}
