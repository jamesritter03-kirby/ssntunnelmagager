import Foundation
import AppKit

/// How lines are terminated on disk. The editor always works in `\n` internally
/// and converts on save.
enum LineEnding: String, CaseIterable, Identifiable, Codable {
    case lf     // \n     (Unix / macOS)
    case crlf   // \r\n   (Windows)
    case cr     // \r     (classic Mac)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lf:   return "LF"
        case .crlf: return "CRLF"
        case .cr:   return "CR"
        }
    }

    /// The characters written to disk for this ending.
    var rawSequence: String {
        switch self {
        case .lf:   return "\n"
        case .crlf: return "\r\n"
        case .cr:   return "\r"
        }
    }

    /// Sniff the dominant line ending in freshly loaded text.
    static func detect(in text: String) -> LineEnding {
        if text.contains("\r\n") { return .crlf }
        if text.contains("\r")   { return .cr }
        return .lf
    }
}

/// A human name for a text encoding, for the status bar.
extension String.Encoding {
    var displayName: String {
        switch self {
        case .utf8:         return "UTF‑8"
        case .utf16:        return "UTF‑16"
        case .utf16BigEndian, .utf16LittleEndian: return "UTF‑16"
        case .ascii:        return "ASCII"
        case .isoLatin1:    return "ISO‑8859‑1"
        case .windowsCP1252: return "Windows‑1252"
        case .macOSRoman:   return "Mac Roman"
        default:            return "UTF‑8"
        }
    }
}

/// Bridges the SwiftUI/model world to the live `NSTextView`. The view layer sets
/// `textView`; the model calls these methods to read text and drive find/replace
/// and navigation without importing any AppKit view code itself.
final class EditorEngine {
    weak var textView: NSTextView?

    /// The full current buffer (`\n`‑delimited).
    var string: String { textView?.string ?? "" }

    // MARK: Matching

    /// All match ranges for a query, in ascending order.
    private func matches(for query: String, caseSensitive: Bool, regex: Bool,
                         wholeWord: Bool) -> [NSRange] {
        guard let tv = textView, !query.isEmpty else { return [] }
        let ns = tv.string as NSString
        let full = NSRange(location: 0, length: ns.length)

        if regex {
            var opts: NSRegularExpression.Options = []
            if !caseSensitive { opts.insert(.caseInsensitive) }
            var pattern = query
            if wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return [] }
            return re.matches(in: tv.string, range: full)
                .map(\.range)
                .filter { $0.length > 0 }
        }

        var opts: NSString.CompareOptions = [.literal]
        if !caseSensitive { opts.insert(.caseInsensitive) }
        var results: [NSRange] = []
        var loc = 0
        while loc < ns.length {
            let searchRange = NSRange(location: loc, length: ns.length - loc)
            let r = ns.range(of: query, options: opts, range: searchRange)
            if r.location == NSNotFound { break }
            if !wholeWord || EditorEngine.isWholeWord(r, in: ns) { results.append(r) }
            loc = r.location + max(r.length, 1)
        }
        return results
    }

    private static func isWholeWord(_ range: NSRange, in ns: NSString) -> Bool {
        let wordChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        if range.location > 0 {
            let before = ns.substring(with: NSRange(location: range.location - 1, length: 1))
            if before.unicodeScalars.allSatisfy(wordChars.contains) { return false }
        }
        let end = range.location + range.length
        if end < ns.length {
            let after = ns.substring(with: NSRange(location: end, length: 1))
            if after.unicodeScalars.allSatisfy(wordChars.contains) { return false }
        }
        return true
    }

    // MARK: Find

    /// Move the selection to the next/previous match relative to the current
    /// caret, wrapping around. Returns the 1‑based index and total match count.
    @discardableResult
    func find(_ query: String, caseSensitive: Bool, regex: Bool, wholeWord: Bool,
              forward: Bool) -> (found: Bool, index: Int, total: Int) {
        guard let tv = textView else { return (false, 0, 0) }
        let all = matches(for: query, caseSensitive: caseSensitive, regex: regex, wholeWord: wholeWord)
        guard !all.isEmpty else { return (false, 0, 0) }
        let sel = tv.selectedRange()
        let target: Int
        if forward {
            target = all.firstIndex { $0.location >= sel.location + max(sel.length, 1) || $0.location > sel.location }
                ?? 0
        } else {
            target = all.lastIndex { $0.location < sel.location } ?? (all.count - 1)
        }
        select(all[target], in: tv)
        return (true, target + 1, all.count)
    }

    /// The total number of matches (for the "N found" readout) without moving.
    func count(_ query: String, caseSensitive: Bool, regex: Bool, wholeWord: Bool) -> Int {
        matches(for: query, caseSensitive: caseSensitive, regex: regex, wholeWord: wholeWord).count
    }

    // MARK: Replace

    /// Replace the current selection if it is exactly a match, then advance.
    /// Returns whether a replacement was made.
    @discardableResult
    func replaceCurrent(_ query: String, with replacement: String, caseSensitive: Bool,
                        regex: Bool, wholeWord: Bool) -> Bool {
        guard let tv = textView else { return false }
        let sel = tv.selectedRange()
        let all = matches(for: query, caseSensitive: caseSensitive, regex: regex, wholeWord: wholeWord)
        guard let m = all.first(where: { $0 == sel }), m.length > 0 else {
            // Not sitting on a match — just jump to the next one.
            find(query, caseSensitive: caseSensitive, regex: regex, wholeWord: wholeWord, forward: true)
            return false
        }
        let repText = expand(replacement, forMatch: m, query: query, caseSensitive: caseSensitive, regex: regex, wholeWord: wholeWord, in: tv)
        if tv.shouldChangeText(in: m, replacementString: repText) {
            tv.textStorage?.replaceCharacters(in: m, with: repText)
            tv.didChangeText()
            let newRange = NSRange(location: m.location, length: (repText as NSString).length)
            tv.setSelectedRange(NSRange(location: newRange.location + newRange.length, length: 0))
        }
        find(query, caseSensitive: caseSensitive, regex: regex, wholeWord: wholeWord, forward: true)
        return true
    }

    /// Replace every match in one undoable step. Returns the number replaced.
    @discardableResult
    func replaceAll(_ query: String, with replacement: String, caseSensitive: Bool,
                    regex: Bool, wholeWord: Bool) -> Int {
        guard let tv = textView else { return 0 }
        let all = matches(for: query, caseSensitive: caseSensitive, regex: regex, wholeWord: wholeWord)
        guard !all.isEmpty else { return 0 }
        let mutable = NSMutableString(string: tv.string)
        var re: NSRegularExpression? = nil
        if regex {
            var opts: NSRegularExpression.Options = []
            if !caseSensitive { opts.insert(.caseInsensitive) }
            var pattern = query
            if wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
            re = try? NSRegularExpression(pattern: pattern, options: opts)
        }
        for m in all.reversed() {
            let rep: String
            if let re {
                let sub = mutable.substring(with: m)
                rep = re.stringByReplacingMatches(in: sub, options: [],
                                                  range: NSRange(location: 0, length: (sub as NSString).length),
                                                  withTemplate: replacement)
            } else {
                rep = replacement
            }
            mutable.replaceCharacters(in: m, with: rep)
        }
        let full = NSRange(location: 0, length: (tv.string as NSString).length)
        let newString = mutable as String
        if tv.shouldChangeText(in: full, replacementString: newString) {
            tv.textStorage?.replaceCharacters(in: full, with: newString)
            tv.didChangeText()
        }
        return all.count
    }

    private func expand(_ replacement: String, forMatch m: NSRange, query: String,
                        caseSensitive: Bool, regex: Bool, wholeWord: Bool,
                        in tv: NSTextView) -> String {
        guard regex else { return replacement }
        var opts: NSRegularExpression.Options = []
        if !caseSensitive { opts.insert(.caseInsensitive) }
        var pattern = query
        if wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return replacement }
        let sub = (tv.string as NSString).substring(with: m)
        return re.stringByReplacingMatches(in: sub, options: [],
                                           range: NSRange(location: 0, length: (sub as NSString).length),
                                           withTemplate: replacement)
    }

    // MARK: Navigation

    /// Select the start of a 1‑based line number and scroll it into view.
    func goToLine(_ line: Int) {
        guard let tv = textView, line >= 1 else { return }
        let ns = tv.string as NSString
        var current = 1
        var idx = 0
        while current < line && idx < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: idx, length: 0))
            idx = NSMaxRange(lineRange)
            current += 1
        }
        let target = NSRange(location: min(idx, ns.length), length: 0)
        select(target, in: tv)
    }

    private func select(_ range: NSRange, in tv: NSTextView) {
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
        if range.length > 0 { tv.showFindIndicator(for: range) }
        tv.window?.makeFirstResponder(tv)
    }
}

/// The document model behind one text‑editor tab: the file identity, editing
/// preferences (language, wrap, line numbers, font size, encoding, line ending),
/// status‑bar readouts, and the find/replace state. The live text lives in the
/// `NSTextView` (reached through `engine`); this model only mirrors the file
/// path so a saved document can be reopened after a relaunch.
final class TextEditorModel: ObservableObject {
    let id: UUID
    let engine = EditorEngine()

    @Published var fileURL: URL?
    @Published var language: CodeLanguage {
        didSet { if language != oldValue { languageManuallySet = true } }
    }
    @Published var isDirty = false
    @Published var wordWrap = false
    @Published var showLineNumbers = true
    @Published var fontSize: Double
    @Published var lineEnding: LineEnding = .lf
    @Published var encoding: String.Encoding = .utf8

    /// The colour theme for this tab. Changing it also updates the app-wide
    /// default so the next new editor tab opens with the same theme.
    @Published var themeID: String {
        didSet {
            if themeID != oldValue { AppSettings.shared.defaultEditorThemeID = themeID }
        }
    }

    // Status‑bar readouts, updated by the editor view's coordinator.
    @Published var caretLine = 1
    @Published var caretColumn = 1
    @Published var lineCount = 1
    @Published var characterCount = 0
    @Published var selectionLength = 0

    // Find/replace bar state.
    @Published var findVisible = false
    @Published var replaceVisible = false
    @Published var findText = ""
    @Published var replaceText = ""
    @Published var findCaseSensitive = false
    @Published var findUsesRegex = false
    @Published var findWholeWord = false
    @Published var findStatus = ""

    /// Bumped whenever the buffer is replaced programmatically (open / new /
    /// reload) so the editor view knows to reload its `NSTextView` contents.
    @Published private(set) var reloadToken = UUID()
    private(set) var pendingContent = ""

    /// How the file on disk currently relates to this buffer. `nil` means in
    /// sync; the other cases drive the "reload?" banner and popup.
    enum ExternalChange: Equatable { case modified, deleted }
    @Published var externalChange: ExternalChange?

    /// Watches the document file for changes made by other programs.
    private let monitor = FileChangeMonitor()
    /// The (modification date, size) we last read from or wrote to disk. External
    /// changes are anything that no longer matches this baseline.
    private var lastKnownModDate: Date?
    private var lastKnownSize: Int?
    /// Re‑entrancy guard so the "file changed on disk" popup is only shown once.
    private var isPresentingExternalPrompt = false
    private var didBecomeActiveObserver: NSObjectProtocol?

    /// Debounces crash‑safe backup writes so we don't hit disk on every keystroke.
    private var backupWorkItem: DispatchWorkItem?

    /// Called with the tab title (name plus a "•" when unsaved) so the session
    /// can retitle the tab.
    var onTitleChange: ((String) -> Void)?

    /// Whether the user explicitly picked a language (so we stop auto‑detecting
    /// from the filename on save).
    private var languageManuallySet = false

    static let minFontSize = 8.0
    static let maxFontSize = 40.0
    static let defaultFontSize = 13.0

    init(path: String? = nil, backupID: UUID? = nil) {
        self.id = backupID ?? UUID()
        self.fontSize = TextEditorModel.defaultFontSize
        self.language = .plainText
        self.themeID = AppSettings.shared.defaultEditorThemeID

        // Prefer restoring unsaved work (a crash‑safe backup) over re‑reading the
        // file from disk, mirroring Notepad++: typed‑but‑never‑saved text and
        // pending edits to a saved file both survive a relaunch.
        if let backupID, let record = EditorBackupStore.shared.load(id: backupID),
           record.isDirty || (record.filePath == nil && !record.content.isEmpty) {
            restoreFromBackup(record)
        } else if let path, !path.isEmpty {
            loadFromDisk(URL(fileURLWithPath: path), announceErrors: false)
        } else {
            newDocument()
        }

        // Re‑check the file whenever the app is reactivated, catching changes made
        // by other programs while we were in the background.
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.checkForExternalChange()
        }
    }

    deinit {
        monitor.stop()
        if let obs = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// The bare document name for the tab / status bar.
    var displayName: String { fileURL?.lastPathComponent ?? "Untitled" }

    // MARK: - Buffer lifecycle

    private func setContent(_ text: String) {
        pendingContent = text
        reloadToken = UUID()
        characterCount = (text as NSString).length
        lineCount = max(1, text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } - (text.hasSuffix("\n") ? 1 : 0))
    }

    /// Mirror the live editor buffer into the model **without** forcing a reload.
    /// The editor view can be torn down and rebuilt (switching to the tiled
    /// layout, moving a tab to a drawer, re‑selecting a tab), which recreates the
    /// `NSTextView` from `pendingContent`. Capturing every edit here keeps that
    /// snapshot current, so a re‑mounted editor restores the text the user typed
    /// instead of reverting to the last opened/saved contents.
    func captureLiveText(_ text: String) {
        pendingContent = text
        scheduleBackup()
    }

    /// Start a fresh, empty, untitled document.
    func newDocument() {
        fileURL = nil
        languageManuallySet = false
        language = .plainText
        languageManuallySet = false
        encoding = .utf8
        lineEnding = .lf
        setContent("")
        isDirty = false
        caretLine = 1; caretColumn = 1; selectionLength = 0
        externalChange = nil
        stopWatching()
        syncBackup()
        updateTitle()
    }

    /// Load a file from disk into the buffer, replacing the current contents.
    func loadFromDisk(_ url: URL, announceErrors: Bool = true) {
        guard let data = try? Data(contentsOf: url) else {
            if announceErrors { presentError("Couldn't Open File",
                                             "\(url.lastPathComponent) could not be read.") }
            newDocument()
            fileURL = url            // remember where it should live even if empty
            updateTitle()
            return
        }
        var used: String.Encoding = .utf8
        let content = TextEditorModel.decode(data, encoding: &used)
        fileURL = url
        encoding = used
        lineEnding = LineEnding.detect(in: content)
        languageManuallySet = false
        language = CodeLanguage.detect(forFileName: url.lastPathComponent)
        languageManuallySet = false
        setContent(content.replacingOccurrences(of: "\r\n", with: "\n")
                          .replacingOccurrences(of: "\r", with: "\n"))
        isDirty = false
        caretLine = 1; caretColumn = 1; selectionLength = 0
        externalChange = nil
        recordDiskBaseline()
        startWatching()
        syncBackup()
        updateTitle()
    }

    private static func decode(_ data: Data, encoding used: inout String.Encoding) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let s = String(data: data, encoding: .utf8) { used = .utf8; return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) { used = .utf16; return s }
        if let s = String(data: data, encoding: .utf8) { used = .utf8; return s }
        for enc: String.Encoding in [.isoLatin1, .windowsCP1252, .macOSRoman] {
            if let s = String(data: data, encoding: enc) { used = enc; return s }
        }
        used = .utf8
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Saving

    /// Save to the current file, or run a Save panel for an untitled document.
    func save() {
        if let url = fileURL { _ = write(to: url) }
        else { saveAs() }
    }

    /// Prompt for a destination and save there.
    func saveAs() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = fileURL?.lastPathComponent
            ?? "Untitled.\(language.preferredExtension ?? "txt")"
        if let dir = fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adoptLanguageIfNeeded(for: url)
        _ = write(to: url)
    }

    /// Synchronous save used by the close/replace confirmation flow. Returns
    /// whether the document ended up saved.
    private func saveSynchronously() -> Bool {
        if let url = fileURL { return write(to: url) }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Untitled.\(language.preferredExtension ?? "txt")"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        adoptLanguageIfNeeded(for: url)
        return write(to: url)
    }

    private func adoptLanguageIfNeeded(for url: URL) {
        if !languageManuallySet {
            let detected = CodeLanguage.detect(forFileName: url.lastPathComponent)
            language = detected
            languageManuallySet = false
        }
    }

    @discardableResult
    private func write(to url: URL) -> Bool {
        let body = currentText
        let out = lineEnding == .lf ? body
            : body.replacingOccurrences(of: "\n", with: lineEnding.rawSequence)
        guard let data = out.data(using: encoding) ?? out.data(using: .utf8) else {
            presentError("Couldn't Save", "The text couldn't be encoded as \(encoding.displayName).")
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            fileURL = url
            isDirty = false
            externalChange = nil
            // Record the just‑written state as the baseline and (re)attach the
            // watcher to the new file, so our own save is never mistaken for an
            // external change and future external edits are still caught.
            recordDiskBaseline()
            startWatching()
            syncBackup()             // clean now → removes the backup
            updateTitle()
            return true
        } catch {
            presentError("Couldn't Save", error.localizedDescription)
            return false
        }
    }

    // MARK: - Opening

    /// Present an Open panel and load the chosen file (guarding unsaved changes).
    func openWithPanel() {
        guard confirmDiscardIfNeeded() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if let dir = fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadFromDisk(url)
    }

    /// Reload the current file from disk, discarding unsaved changes (after
    /// confirmation).
    func revertToSaved() {
        guard let url = fileURL else { return }
        guard confirmDiscardIfNeeded() else { return }
        loadFromDisk(url)
    }

    // MARK: - Dirty tracking & title

    func markDirty() {
        if !isDirty { isDirty = true; updateTitle() }
        scheduleBackup()
    }

    private func updateTitle() {
        onTitleChange?((isDirty ? "• " : "") + displayName)
    }

    /// Push the current title to the owning session. Called once after the
    /// session wires `onTitleChange`, so a document restored as "dirty" shows its
    /// "•" marker immediately instead of only after the next edit.
    func refreshTitle() { updateTitle() }

    // MARK: - Close / discard confirmation

    /// Ask to save when there are unsaved changes. Returns `true` if it's OK to
    /// proceed (the caller may close/replace the buffer), `false` to abort.
    func confirmCloseIfNeeded() -> Bool { confirmDiscardIfNeeded() }

    private func confirmDiscardIfNeeded() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to “\(displayName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return saveSynchronously()
        case .alertSecondButtonReturn: return true
        default:                       return false
        }
    }

    // MARK: - Find / replace (delegates to the live text view)

    func findNext() { runFind(forward: true) }
    func findPrevious() { runFind(forward: false) }

    private func runFind(forward: Bool) {
        guard !findText.isEmpty else { findStatus = ""; return }
        let r = engine.find(findText, caseSensitive: findCaseSensitive, regex: findUsesRegex,
                            wholeWord: findWholeWord, forward: forward)
        findStatus = r.found ? "\(r.index) of \(r.total)" : "Not found"
    }

    /// Update just the "N found" readout as the query/options change.
    func refreshFindCount() {
        guard !findText.isEmpty else { findStatus = ""; return }
        let n = engine.count(findText, caseSensitive: findCaseSensitive, regex: findUsesRegex,
                            wholeWord: findWholeWord)
        findStatus = n == 0 ? "Not found" : "\(n) found"
    }

    func replaceCurrent() {
        guard !findText.isEmpty else { return }
        _ = engine.replaceCurrent(findText, with: replaceText, caseSensitive: findCaseSensitive,
                                  regex: findUsesRegex, wholeWord: findWholeWord)
        markDirty()
        refreshFindCount()
    }

    func replaceAll() {
        guard !findText.isEmpty else { return }
        let n = engine.replaceAll(findText, with: replaceText, caseSensitive: findCaseSensitive,
                                  regex: findUsesRegex, wholeWord: findWholeWord)
        if n > 0 { markDirty() }
        findStatus = "Replaced \(n)"
    }

    func openFindBar(replace: Bool) {
        findVisible = true
        replaceVisible = replace
        refreshFindCount()
    }

    func closeFindBar() {
        findVisible = false
        replaceVisible = false
        findStatus = ""
    }

    // MARK: - Font zoom

    func increaseFont() { fontSize = min(TextEditorModel.maxFontSize, fontSize + 1) }
    func decreaseFont() { fontSize = max(TextEditorModel.minFontSize, fontSize - 1) }
    func resetFont() { fontSize = TextEditorModel.defaultFontSize }

    // MARK: - Crash‑safe backups (unsaved‑text restore)

    /// The authoritative current buffer: the live text view when mounted, else
    /// the last text mirrored from it (a backgrounded tab has no live view).
    private var currentText: String {
        engine.textView != nil ? engine.string : pendingContent
    }

    /// Restore a document from its saved backup (unsaved edits or an untitled
    /// buffer). Used on relaunch so typed‑but‑never‑saved text isn't lost.
    private func restoreFromBackup(_ record: EditorBackupRecord) {
        if let path = record.filePath { fileURL = URL(fileURLWithPath: path) }
        if let lang = CodeLanguage(rawValue: record.language) { language = lang }
        if let ending = LineEnding(rawValue: record.lineEnding) { lineEnding = ending }
        encoding = String.Encoding(rawValue: record.encoding)
        languageManuallySet = false
        setContent(record.content)
        isDirty = record.isDirty
        caretLine = 1; caretColumn = 1; selectionLength = 0
        externalChange = nil
        // Baseline against the file as it currently is on disk (we keep the user's
        // unsaved buffer), and watch it for any *future* external change.
        if fileURL != nil {
            recordDiskBaseline()
            startWatching()
        }
        updateTitle()
    }

    /// Debounce a backup write so we don't touch disk on every keystroke.
    private func scheduleBackup() {
        backupWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.syncBackup() }
        backupWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    /// Write a backup while there's unsaved work worth restoring, or remove it
    /// once the document is clean/empty.
    private func syncBackup() {
        let content = currentText
        let worthKeeping = isDirty || (fileURL == nil && !content.isEmpty)
        if worthKeeping {
            let record = EditorBackupRecord(filePath: fileURL?.path,
                                            content: content,
                                            isDirty: isDirty,
                                            language: language.rawValue,
                                            lineEnding: lineEnding.rawValue,
                                            encoding: encoding.rawValue)
            EditorBackupStore.shared.write(id: id, record: record)
        } else {
            EditorBackupStore.shared.remove(id: id)
        }
    }

    /// Force the backup up to date immediately (used on app termination and when
    /// the session state is snapshotted).
    func flushBackup() {
        backupWorkItem?.cancel()
        backupWorkItem = nil
        syncBackup()
    }

    /// Drop this document's backup — the tab was closed after the unsaved‑changes
    /// prompt, so there's nothing left to restore.
    func discardBackup() {
        backupWorkItem?.cancel()
        backupWorkItem = nil
        EditorBackupStore.shared.remove(id: id)
    }

    // MARK: - External‑change monitoring

    /// Remember the file's on‑disk fingerprint so we can tell our own writes from
    /// changes made by other programs.
    private func recordDiskBaseline() {
        guard let url = fileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            lastKnownModDate = nil; lastKnownSize = nil; return
        }
        lastKnownModDate = attrs[.modificationDate] as? Date
        lastKnownSize = (attrs[.size] as? NSNumber)?.intValue
    }

    private func startWatching() {
        guard let url = fileURL else { stopWatching(); return }
        monitor.onChange = { [weak self] in self?.checkForExternalChange() }
        monitor.start(url: url)
    }

    private func stopWatching() { monitor.stop() }

    /// Compare the file on disk to our recorded baseline and flag any external
    /// modification or deletion. Cheap enough to call on every watcher event and
    /// whenever the app is reactivated.
    private func checkForExternalChange() {
        guard let url = fileURL else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            if externalChange != .deleted { externalChange = .deleted }
            return
        }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return }
        let modDate = attrs[.modificationDate] as? Date
        let size = (attrs[.size] as? NSNumber)?.intValue
        if modDate != lastKnownModDate || size != lastKnownSize {
            if externalChange != .modified { externalChange = .modified }
        }
    }

    /// Show the "file changed on disk" popup for the current change, if any. The
    /// editor view calls this when it's the visible tab (on appear, on change, or
    /// when the app is reactivated). Guarded so it only appears once at a time.
    func presentExternalChangePromptIfNeeded() {
        guard NSApp.isActive, !isPresentingExternalPrompt, let change = externalChange else { return }
        isPresentingExternalPrompt = true
        defer { isPresentingExternalPrompt = false }
        switch change {
        case .modified:
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "“\(displayName)” changed on disk"
            alert.informativeText = isDirty
                ? "Another program modified this file, but you have unsaved changes here. Reloading replaces your version with the one on disk."
                : "Another program modified this file. Do you want to reload it?"
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Keep My Version")
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = fileURL { loadFromDisk(url) }
            } else {
                keepMyVersion()
            }
        case .deleted:
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "“\(displayName)” was moved or deleted"
            alert.informativeText = "The file is no longer at its original location. Your text is kept here — save it again to write a new copy."
            alert.addButton(withTitle: "Keep in Editor")
            alert.runModal()
            markDirty()                 // now diverges from the (missing) file
            externalChange = nil
            lastKnownModDate = nil
            lastKnownSize = nil
        }
    }

    /// Keep the in‑editor version after an external change: adopt the file's new
    /// on‑disk fingerprint as the baseline (so we stop warning about *this*
    /// change) and treat our buffer as unsaved edits layered on top.
    private func keepMyVersion() {
        recordDiskBaseline()
        markDirty()
        externalChange = nil
    }

    /// Banner action: reload the file from disk, discarding the in‑editor version.
    func reloadFromDiskExternal() {
        guard let url = fileURL else { externalChange = nil; return }
        loadFromDisk(url)
    }

    /// Banner action: keep the in‑editor version and stop warning about the
    /// current external change (whether the file was modified or removed).
    func dismissExternalChange() {
        switch externalChange {
        case .modified:
            keepMyVersion()
        case .deleted:
            markDirty()
            externalChange = nil
            lastKnownModDate = nil
            lastKnownSize = nil
        case .none:
            break
        }
    }

    // MARK: - Helpers

    private func presentError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
