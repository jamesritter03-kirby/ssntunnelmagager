import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

/// The document model behind one **spreadsheet** tab: a delimited (CSV / TSV)
/// file parsed into a grid of columns and rows, with in‑place cell editing,
/// row / column insertion & deletion, sorting, and save‑back to disk (or to an
/// SFTP server when opened remotely).
///
/// Columns and rows carry stable `UUID` identities so cells stay correctly
/// mapped as columns are inserted, deleted or reordered — the grid view keys its
/// `NSTableColumn`s off these ids. The live grid reads `columns` / `rows`; this
/// model owns every mutation so dirty‑tracking, titles and serialization stay in
/// one place.
final class SpreadsheetModel: ObservableObject {

    /// A column in the sheet. `name` is the header label (also written as the
    /// first CSV row when `hasHeaderRow` is on).
    struct Column: Identifiable, Equatable {
        let id: UUID
        var name: String
        init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
    }

    /// One data row: cell text keyed by column id (missing == empty string).
    struct Row: Identifiable, Equatable {
        let id: UUID
        var cells: [UUID: String]
        init(id: UUID = UUID(), cells: [UUID: String] = [:]) { self.id = id; self.cells = cells }
    }

    /// The stored data of one worksheet in a workbook. The **active** sheet's
    /// data lives in the published `columns` / `rows` / `hasHeaderRow`; inactive
    /// sheets are parked here and swapped in on `switchToSheet`.
    struct SheetData {
        var name: String
        var columns: [Column]
        var rows: [Row]
        var hasHeaderRow: Bool
    }

    /// The field separator used when parsing and writing the file.
    enum Delimiter: String, CaseIterable, Identifiable {
        case comma, tab, semicolon, pipe
        var id: String { rawValue }

        var character: Character {
            switch self {
            case .comma:     return ","
            case .tab:       return "\t"
            case .semicolon: return ";"
            case .pipe:      return "|"
            }
        }

        var displayName: String {
            switch self {
            case .comma:     return "Comma"
            case .tab:       return "Tab"
            case .semicolon: return "Semicolon"
            case .pipe:      return "Pipe"
            }
        }

        /// The default file extension for this delimiter.
        var fileExtension: String { self == .tab ? "tsv" : "csv" }
    }

    // MARK: - Published state

    let id: UUID
    @Published var fileURL: URL?
    @Published private(set) var columns: [Column] = []
    @Published private(set) var rows: [Row] = []
    @Published var isDirty = false
    @Published var delimiter: Delimiter
    /// When true, the first line of the file is the header (its values become the
    /// column names); when false, columns get spreadsheet‑style names (A, B, C…).
    @Published var hasHeaderRow: Bool = true
    /// The current selection (row indices), mirrored from the grid so the toolbar
    /// can act on it (delete rows, insert relative to it).
    @Published var selectedRows = IndexSet()

    /// Bumped on any **structural** change (load, add / delete / sort rows or
    /// columns) so the grid knows to rebuild its table; plain cell edits don't
    /// bump it (the table already shows the typed value).
    @Published private(set) var structureRevision = 0

    /// True when the document is an Excel workbook (`.xlsx`) rather than a plain
    /// delimited text file. Drives the sheet bar and format‑specific UI.
    @Published private(set) var isExcel = false
    /// The workbook's worksheet names, in order (empty for a CSV / TSV file).
    @Published private(set) var sheetNames: [String] = []
    /// Which worksheet is currently shown in the grid.
    @Published private(set) var activeSheetIndex = 0

    /// When set, this sheet is a remote file (opened from an SFTP tab) uploaded
    /// back to its server on every save. Reuses the editor's upload plumbing.
    @Published var remoteEdit: RemoteEditLink?
    @Published var remoteSyncState: RemoteSyncState = .idle

    @Published var errorMessage: String?

    /// Called with the tab title (name plus a "•" when unsaved).
    var onTitleChange: ((String) -> Void)?

    /// The last loaded / saved file text, so switching the delimiter can
    /// re‑interpret the same bytes.
    private var sourceText: String?

    /// All worksheets of an Excel workbook (including the active one, whose live
    /// copy is `columns` / `rows`). Empty for delimited files.
    private var sheetStore: [SheetData] = []

    // MARK: - Init

    init(path: String? = nil) {
        self.id = UUID()
        self.delimiter = .comma
        if let path, !path.isEmpty {
            loadFromDisk(URL(fileURLWithPath: path))
        } else {
            newDocument()
        }
    }

    // MARK: - Derived

    var displayName: String { fileURL?.lastPathComponent ?? "Untitled" }
    var rowCount: Int { rows.count }
    var columnCount: Int { columns.count }

    /// A signature the grid compares to decide whether to rebuild its columns.
    var columnSignature: String {
        columns.map { "\($0.id.uuidString):\($0.name)" }.joined(separator: "|")
    }

    func cell(rowIndex: Int, columnID: UUID) -> String {
        guard rows.indices.contains(rowIndex) else { return "" }
        return rows[rowIndex].cells[columnID] ?? ""
    }

    // MARK: - New / load

    func newDocument() {
        // A small starter grid: 3 columns × 3 empty rows.
        let cols = ["A", "B", "C"].map { Column(name: $0) }
        columns = cols
        rows = (0..<3).map { _ in Row(cells: [:]) }
        hasHeaderRow = false
        fileURL = nil
        sourceText = nil
        isExcel = false
        sheetStore = []
        sheetNames = []
        activeSheetIndex = 0
        isDirty = false
        bumpStructure()
        updateTitle()
    }

    func loadFromDisk(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if SpreadsheetModel.isExcelExtension(ext) {
            loadExcel(url)
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Couldn’t read \(url.lastPathComponent)."
            newDocument()
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        // Detect the delimiter from the first non-empty line unless the extension
        // makes it obvious.
        if ext == "tsv" || ext == "tab" { delimiter = .tab }
        else { delimiter = SpreadsheetModel.detectDelimiter(in: text) }
        isExcel = false
        sheetStore = []
        sheetNames = []
        activeSheetIndex = 0
        fileURL = url
        load(text: text, hasHeader: true)
        isDirty = false
        updateTitle()
    }

    /// Parse `text` with the current delimiter into columns + rows.
    private func load(text: String, hasHeader: Bool) {
        sourceText = text
        let records = SpreadsheetModel.parse(text, delimiter: delimiter.character)
        let built = buildColumnsRows(from: records, hasHeader: hasHeader)
        columns = built.columns
        rows = built.rows
        hasHeaderRow = built.hasHeader
        bumpStructure()
    }

    /// Turn a table of raw string records into identity‑keyed columns + rows,
    /// honouring the header‑row choice. Shared by the CSV and Excel loaders.
    private func buildColumnsRows(from records: [[String]], hasHeader: Bool)
        -> (columns: [Column], rows: [Row], hasHeader: Bool) {
        var recs = records
        if recs.isEmpty { recs = [[]] }
        let width = max(recs.map(\.count).max() ?? 0, 1)
        let header = hasHeader && recs.count > 1
        let cols: [Column]
        let dataRecords: ArraySlice<[String]>
        if header, let head = recs.first {
            cols = (0..<width).map { i in
                let name = i < head.count ? head[i] : SpreadsheetModel.columnLetters(i)
                return Column(name: name.isEmpty ? SpreadsheetModel.columnLetters(i) : name)
            }
            dataRecords = recs.dropFirst()
        } else {
            cols = (0..<width).map { Column(name: SpreadsheetModel.columnLetters($0)) }
            dataRecords = recs[...]
        }
        let builtRows = dataRecords.map { record -> Row in
            var cells: [UUID: String] = [:]
            for (i, col) in cols.enumerated() where i < record.count {
                cells[col.id] = record[i]
            }
            return Row(cells: cells)
        }
        return (cols, builtRows, header)
    }

    // MARK: - Excel (.xlsx) workbooks

    static func isExcelExtension(_ ext: String) -> Bool {
        ["xlsx", "xlsm", "xltx", "xltm"].contains(ext.lowercased())
    }

    private func loadExcel(_ url: URL) {
        do {
            let parsed = try XLSXDocument.read(from: url)
            var store: [SheetData] = []
            for sheet in parsed {
                let built = buildColumnsRows(from: sheet.rows, hasHeader: true)
                store.append(SheetData(name: sheet.name, columns: built.columns,
                                       rows: built.rows, hasHeaderRow: built.hasHeader))
            }
            if store.isEmpty { store = [SpreadsheetModel.blankSheet(named: "Sheet1")] }
            sheetStore = store
            isExcel = true
            sheetNames = store.map(\.name)
            fileURL = url
            sourceText = nil
            loadSheet(0)
            isDirty = false
            updateTitle()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            presentError("Couldn’t Open Workbook", message)
            newDocument()
        }
    }

    private static func blankSheet(named name: String) -> SheetData {
        SheetData(name: name, columns: ["A", "B", "C"].map { Column(name: $0) },
                  rows: (0..<3).map { _ in Row() }, hasHeaderRow: false)
    }

    /// Load one stored worksheet into the live grid.
    private func loadSheet(_ index: Int) {
        guard sheetStore.indices.contains(index) else { return }
        activeSheetIndex = index
        let s = sheetStore[index]
        columns = s.columns
        rows = s.rows
        hasHeaderRow = s.hasHeaderRow
        selectedRows = IndexSet()
        bumpStructure()
    }

    /// Copy the live grid back into the active worksheet's stored data.
    private func flushActiveSheet() {
        guard sheetStore.indices.contains(activeSheetIndex) else { return }
        sheetStore[activeSheetIndex].columns = columns
        sheetStore[activeSheetIndex].rows = rows
        sheetStore[activeSheetIndex].hasHeaderRow = hasHeaderRow
    }

    /// A snapshot of the live grid as a single worksheet (used when a CSV / new
    /// document is first turned into a workbook).
    private func currentSheetData() -> SheetData {
        let name = sheetStore.indices.contains(activeSheetIndex)
            ? sheetStore[activeSheetIndex].name
            : (fileURL?.deletingPathExtension().lastPathComponent ?? "Sheet1")
        return SheetData(name: name, columns: columns, rows: rows, hasHeaderRow: hasHeaderRow)
    }

    /// Switch the visible worksheet (Excel workbooks).
    func switchToSheet(_ index: Int) {
        guard index != activeSheetIndex, sheetStore.indices.contains(index) else { return }
        flushActiveSheet()
        loadSheet(index)
        updateTitle()
    }

    /// Add a new blank worksheet and switch to it (turning the document into a
    /// workbook if it wasn't one already).
    func addSheet() {
        flushActiveSheet()
        if sheetStore.isEmpty {
            sheetStore = [currentSheetData()]
            activeSheetIndex = 0
        }
        sheetStore.append(SpreadsheetModel.blankSheet(named: uniqueSheetName()))
        isExcel = true
        sheetNames = sheetStore.map(\.name)
        markDirty()
        loadSheet(sheetStore.count - 1)
        updateTitle()
    }

    /// Delete a worksheet (a workbook always keeps at least one).
    func deleteSheet(at index: Int) {
        guard sheetStore.count > 1, sheetStore.indices.contains(index) else { return }
        flushActiveSheet()
        sheetStore.remove(at: index)
        sheetNames = sheetStore.map(\.name)
        let target = activeSheetIndex >= index ? activeSheetIndex - 1 : activeSheetIndex
        markDirty()
        loadSheet(min(max(0, target), sheetStore.count - 1))
        updateTitle()
    }

    /// Rename a worksheet.
    func renameSheet(at index: Int, to name: String) {
        guard sheetStore.indices.contains(index) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sheetStore[index].name = trimmed
        sheetNames = sheetStore.map(\.name)
        markDirty()
    }

    private func uniqueSheetName() -> String {
        let existing = Set(sheetStore.map(\.name))
        var i = sheetStore.count + 1
        while existing.contains("Sheet\(i)") { i += 1 }
        return "Sheet\(i)"
    }

    // MARK: - Delimiter / header

    /// Re‑interpret the current file text with a new delimiter.
    func changeDelimiter(to d: Delimiter) {
        guard !isExcel else { return }   // meaningless for a workbook
        guard d != delimiter else { return }
        if let src = sourceText, !src.isEmpty {
            guard confirmDiscardIfNeeded() else { return }
            delimiter = d
            load(text: src, hasHeader: hasHeaderRow)
            isDirty = false
        } else {
            delimiter = d
            markDirty()
        }
        updateTitle()
    }

    /// Flip whether the first row is treated as a header, converting in place.
    func toggleHeaderRow() {
        if hasHeaderRow {
            // Demote the header names into a new first data row, then rename the
            // columns generically.
            var cells: [UUID: String] = [:]
            for col in columns { cells[col.id] = col.name }
            rows.insert(Row(cells: cells), at: 0)
            for i in columns.indices { columns[i].name = SpreadsheetModel.columnLetters(i) }
            hasHeaderRow = false
        } else if let first = rows.first {
            // Promote the first data row to the header.
            for i in columns.indices {
                let v = first.cells[columns[i].id] ?? ""
                columns[i].name = v.isEmpty ? SpreadsheetModel.columnLetters(i) : v
            }
            rows.removeFirst()
            hasHeaderRow = true
        } else {
            hasHeaderRow = true
        }
        markDirty()
        bumpStructure()
    }

    // MARK: - Cell editing

    /// Set a cell's value (from the grid). Marks dirty but doesn't rebuild the
    /// table — the field already shows the typed text.
    func setCell(rowIndex: Int, columnID: UUID, value: String) {
        guard rows.indices.contains(rowIndex) else { return }
        if (rows[rowIndex].cells[columnID] ?? "") == value { return }
        rows[rowIndex].cells[columnID] = value
        markDirty()
    }

    // MARK: - Rows

    func addRow(at index: Int? = nil) {
        let row = Row(cells: [:])
        let i = index.map { min(max($0, 0), rows.count) } ?? rows.count
        rows.insert(row, at: i)
        markDirty(); bumpStructure()
    }

    /// Add a row below the current selection (or at the end).
    func addRowBelowSelection() {
        addRow(at: selectedRows.max().map { $0 + 1 })
    }

    func deleteRows(_ indices: IndexSet) {
        guard !indices.isEmpty else { return }
        rows.remove(atOffsets: indices)
        selectedRows = IndexSet()
        markDirty(); bumpStructure()
    }

    func deleteSelectedRows() { deleteRows(selectedRows) }

    // MARK: - Columns

    func addColumn(named name: String? = nil, at index: Int? = nil) {
        let i = index.map { min(max($0, 0), columns.count) } ?? columns.count
        let col = Column(name: name ?? SpreadsheetModel.columnLetters(columns.count))
        columns.insert(col, at: i)
        markDirty(); bumpStructure()
    }

    func deleteColumn(at index: Int) {
        guard columns.indices.contains(index) else { return }
        let removed = columns.remove(at: index)
        for r in rows.indices { rows[r].cells[removed.id] = nil }
        markDirty(); bumpStructure()
    }

    func renameColumn(at index: Int, to name: String) {
        guard columns.indices.contains(index) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        columns[index].name = trimmed.isEmpty ? SpreadsheetModel.columnLetters(index) : trimmed
        markDirty(); bumpStructure()
    }

    // MARK: - Sorting

    /// Sort the rows by a column's values, numerically when both compare as
    /// numbers, else case‑insensitively. Reorders the data (persisted on save).
    func sortRows(byColumnID columnID: UUID, ascending: Bool) {
        rows.sort { a, b in
            let x = a.cells[columnID] ?? ""
            let y = b.cells[columnID] ?? ""
            let result: Bool
            if let nx = Double(x), let ny = Double(y), nx != ny {
                result = nx < ny
            } else {
                result = x.localizedStandardCompare(y) == .orderedAscending
            }
            return ascending ? result : !result
        }
        markDirty(); bumpStructure()
    }

    // MARK: - Saving

    func save() {
        if let url = fileURL { _ = write(to: url) } else { saveAs() }
    }

    func saveAs() {
        let panel = makeSavePanel()
        if let dir = fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if write(to: url) {
            // A local "Save As" detaches any remote link.
            remoteEdit = nil
            remoteSyncState = .idle
            updateTitle()
        }
    }

    private func saveSynchronously() -> Bool {
        if let url = fileURL { return write(to: url) }
        let panel = makeSavePanel()
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    /// A Save panel whose format popup offers Excel plus the delimited text
    /// formats; the chosen extension decides how `write(to:)` serializes.
    private func makeSavePanel() -> NSSavePanel {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        var types: [UTType] = []
        if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
        types.append(.commaSeparatedText)
        if let tsv = UTType(filenameExtension: "tsv") { types.append(tsv) }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = defaultSaveName()
        return panel
    }

    private func defaultSaveName() -> String {
        if let name = fileURL?.lastPathComponent { return name }
        return "Untitled." + (isExcel ? "xlsx" : delimiter.fileExtension)
    }

    @discardableResult
    private func write(to url: URL) -> Bool {
        if SpreadsheetModel.isExcelExtension(url.pathExtension) {
            return writeExcel(to: url)
        }
        return writeDelimited(to: url)
    }

    private func writeDelimited(to url: URL) -> Bool {
        let text = serialize()
        guard let data = text.data(using: .utf8) else {
            presentError("Couldn’t Save", "The sheet couldn’t be encoded as UTF‑8.")
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            fileURL = url
            sourceText = text
            // Saving to a delimited file makes this a text document again.
            isExcel = false
            sheetStore = []
            sheetNames = []
            activeSheetIndex = 0
            isDirty = false
            updateTitle()
            if let link = remoteEdit, url == link.localURL { pushToRemote(link) }
            return true
        } catch {
            presentError("Couldn’t Save", error.localizedDescription)
            return false
        }
    }

    private func writeExcel(to url: URL) -> Bool {
        flushActiveSheet()
        let dataSheets: [SheetData] = (isExcel && !sheetStore.isEmpty)
            ? sheetStore : [currentSheetData()]
        let xlsxSheets = dataSheets.map { sheet -> XLSXDocument.Sheet in
            var rows: [[String]] = []
            if sheet.hasHeaderRow {
                rows.append(sheet.columns.map { $0.name })
            }
            for row in sheet.rows {
                rows.append(sheet.columns.map { row.cells[$0.id] ?? "" })
            }
            return XLSXDocument.Sheet(name: sheet.name, rows: rows)
        }
        do {
            try XLSXDocument.write(sheets: xlsxSheets, to: url)
            fileURL = url
            sourceText = nil
            // Becoming (or staying) a workbook: keep the sheet store + bar in sync.
            if !isExcel || sheetStore.isEmpty {
                sheetStore = dataSheets
                activeSheetIndex = 0
            }
            isExcel = true
            sheetNames = sheetStore.map(\.name)
            isDirty = false
            updateTitle()
            if let link = remoteEdit, url == link.localURL { pushToRemote(link) }
            return true
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            presentError("Couldn’t Save", message)
            return false
        }
    }

    /// Serialize the grid back to delimited text (RFC‑4180 quoting).
    func serialize() -> String {
        let sep = delimiter.character
        var lines: [String] = []
        if hasHeaderRow {
            lines.append(columns.map { SpreadsheetModel.quote($0.name, sep: sep) }
                .joined(separator: String(sep)))
        }
        for row in rows {
            let fields = columns.map { SpreadsheetModel.quote(row.cells[$0.id] ?? "", sep: sep) }
            lines.append(fields.joined(separator: String(sep)))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reload from disk, discarding unsaved changes (after confirmation).
    func revertToSaved() {
        guard let url = fileURL else { return }
        guard confirmDiscardIfNeeded() else { return }
        loadFromDisk(url)
    }

    /// Prompt for a delimited or Excel file and load it into this tab.
    func openWithPanel() {
        guard confirmDiscardIfNeeded() else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        var types: [UTType] = []
        if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
        types.append(.commaSeparatedText)
        if let tsv = UTType(filenameExtension: "tsv") { types.append(tsv) }
        types.append(contentsOf: [.plainText, .text])
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url { loadFromDisk(url) }
    }

    /// Save the sheet (prompting for a location when it's still untitled) and
    /// open the file in Microsoft Excel. Falls back to the system's default
    /// spreadsheet app (e.g. Numbers) when Excel isn't installed.
    func openInExcel() {
        if isDirty || fileURL == nil {
            guard saveSynchronously() else { return }   // user cancelled the save
        }
        guard let url = fileURL else { return }
        let ws = NSWorkspace.shared
        if let excel = ws.urlForApplication(withBundleIdentifier: "com.microsoft.Excel") {
            let config = NSWorkspace.OpenConfiguration()
            ws.open([url], withApplicationAt: excel, configuration: config) { [weak self] _, error in
                if let error {
                    DispatchQueue.main.async {
                        self?.presentError("Couldn’t Open in Excel", error.localizedDescription)
                    }
                }
            }
        } else {
            // Excel isn't installed — open with whatever handles CSV / TSV files.
            ws.open(url)
        }
    }

    // MARK: - Remote (SFTP) editing

    func beginRemoteEdit(uploader: RemoteFileUploader, localURL: URL,
                         remoteName: String, remotePath: String, serverLabel: String) {
        remoteEdit = RemoteEditLink(uploader: uploader, localURL: localURL,
                                    remoteName: remoteName, remotePath: remotePath,
                                    serverLabel: serverLabel)
        remoteSyncState = .synced
    }

    private func pushToRemote(_ link: RemoteEditLink) {
        guard let uploader = link.uploader, uploader.isConnected else {
            remoteSyncState = .failed("SFTP connection closed")
            presentError("Couldn’t Upload to Server",
                         "The SFTP connection for “\(link.remoteName)” is no longer open. "
                         + "Your changes were saved locally to:\n\n\(link.localURL.path)")
            return
        }
        remoteSyncState = .syncing
        uploader.uploadFile(at: link.localURL, toRemotePath: link.remotePath) { [weak self] ok in
            DispatchQueue.main.async {
                self?.remoteSyncState = ok ? .synced : .failed("Upload failed — see the SFTP tab’s log")
            }
        }
    }

    // MARK: - Dirty / title / close

    func markDirty() {
        if !isDirty { isDirty = true; updateTitle() }
    }

    private func updateTitle() {
        onTitleChange?((isDirty ? "• " : "") + displayName)
    }

    func refreshTitle() { updateTitle() }

    private func bumpStructure() { structureRevision &+= 1 }

    /// Ask to save when there are unsaved changes. Returns true if it's OK to
    /// proceed (close/replace), false to abort.
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

    private func presentError(_ title: String, _ message: String) {
        errorMessage = message
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - CSV parsing / quoting helpers

    /// Parse delimited text into records of fields, honoring RFC‑4180 quoting:
    /// double‑quoted fields may contain the delimiter, newlines and doubled
    /// quotes (`""`).
    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var records: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character? = nil

        func nextChar() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let ch = nextChar() {
            if inQuotes {
                if ch == "\"" {
                    if let n = nextChar() {
                        if n == "\"" { field.append("\"") }   // escaped quote
                        else { inQuotes = false; pending = n }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case "\"":
                    inQuotes = true
                case delimiter:
                    record.append(field); field = ""
                case "\r":
                    // Swallow a following \n (CRLF).
                    if let n = nextChar(), n != "\n" { pending = n }
                    record.append(field); field = ""
                    records.append(record); record = []
                case "\n":
                    record.append(field); field = ""
                    records.append(record); record = []
                default:
                    field.append(ch)
                }
            }
        }
        // Flush the final field / record unless the text ended on a clean newline.
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }

    /// Quote a field for output if it contains the delimiter, a quote, or a
    /// newline; doubles any embedded quotes.
    static func quote(_ value: String, sep: Character) -> String {
        let needsQuoting = value.contains(sep) || value.contains("\"")
            || value.contains("\n") || value.contains("\r")
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Guess the most likely delimiter from the first non-empty line.
    static func detectDelimiter(in text: String) -> Delimiter {
        let firstLine = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? ""
        let counts: [(Delimiter, Int)] = Delimiter.allCases.map { d in
            (d, firstLine.filter { $0 == d.character }.count)
        }
        if let best = counts.max(by: { $0.1 < $1.1 }), best.1 > 0 { return best.0 }
        return .comma
    }

    /// Spreadsheet-style column name for a 0-based index: A, B, … Z, AA, AB, …
    static func columnLetters(_ index: Int) -> String {
        var n = index
        var name = ""
        repeat {
            name = String(UnicodeScalar(UInt8(65 + n % 26))) + name
            n = n / 26 - 1
        } while n >= 0
        return name
    }
}
