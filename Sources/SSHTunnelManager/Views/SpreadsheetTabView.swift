import SwiftUI
import AppKit

/// A spreadsheet tab: an action toolbar, a native editable grid (an
/// `NSTableView` with a row‑number gutter, resizable & sortable columns, and a
/// header context menu), and a status bar. All state lives in the session's
/// `SpreadsheetModel`.
struct SpreadsheetTabView: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var model: SpreadsheetModel

    init(session: TerminalSession) {
        self.session = session
        self.model = session.spreadsheetModel ?? SpreadsheetModel()
    }

    /// The worksheet currently being renamed (drives the rename alert).
    @State private var renamingSheetIndex: Int?
    @State private var sheetNameDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            SpreadsheetGridView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.isExcel {
                Divider()
                sheetBar
            }
            Divider()
            statusBar
        }
        .background(Color(nsColor: .textBackgroundColor))
        .alert("Rename Sheet", isPresented: Binding(
            get: { renamingSheetIndex != nil },
            set: { if !$0 { renamingSheetIndex = nil } }
        )) {
            TextField("Sheet name", text: $sheetNameDraft)
            Button("Cancel", role: .cancel) { renamingSheetIndex = nil }
            Button("Rename") {
                if let i = renamingSheetIndex { model.renameSheet(at: i, to: sheetNameDraft) }
                renamingSheetIndex = nil
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            toolButton("doc.badge.plus", "New", help: "New empty sheet") {
                if model.confirmCloseIfNeeded() { model.newDocument() }
            }
            toolButton("folder", "Open", help: "Open a CSV, TSV, or Excel file…") {
                model.openWithPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
            toolButton("square.and.arrow.down", "Save", help: "Save") {
                model.save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(model.fileURL != nil && !model.isDirty)
            toolButton("square.and.arrow.down.on.square", "Save As", help: "Save As…") {
                model.saveAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Divider().frame(height: 18)

            toolButton("plus.rectangle.portrait", "Add Row", help: "Add a row below the selection") {
                model.addRowBelowSelection()
            }
            toolButton("minus.rectangle.portrait", "Delete Row",
                       help: "Delete the selected row(s)") {
                model.deleteSelectedRows()
            }
            .disabled(model.selectedRows.isEmpty)
            toolButton("plus.rectangle", "Add Column", help: "Add a column on the right") {
                model.addColumn()
            }

            Divider().frame(height: 18)

            toggleButton("tablecells.badge.ellipsis", "Header Row",
                         isOn: model.hasHeaderRow,
                         help: "Treat the first row as column headers") {
                model.toggleHeaderRow()
            }

            if model.isExcel {
                Label("Excel workbook", systemImage: "tablecells.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            } else {
                delimiterMenu
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var delimiterMenu: some View {
        Menu {
            ForEach(SpreadsheetModel.Delimiter.allCases) { d in
                Button {
                    model.changeDelimiter(to: d)
                } label: {
                    if d == model.delimiter {
                        Label(d.displayName, systemImage: "checkmark")
                    } else {
                        Text(d.displayName)
                    }
                }
            }
        } label: {
            Label(model.delimiter.displayName, systemImage: "chevron.left.slash.chevron.right")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Field separator used to read and write this file")
    }

    // MARK: - Worksheet bar (Excel workbooks)

    private var sheetBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(model.sheetNames.enumerated()), id: \.offset) { index, name in
                        sheetChip(index: index, name: name)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            Divider().frame(height: 20)
            Button {
                model.addSheet()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Add a worksheet")
            .padding(.horizontal, 2)
        }
        .background(.bar)
    }

    private func sheetChip(index: Int, name: String) -> some View {
        let isActive = index == model.activeSheetIndex
        return Text(name.isEmpty ? "Sheet\(index + 1)" : name)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isActive ? Color.accentColor.opacity(0.22) : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(isActive ? Color.accentColor : Color.secondary.opacity(0.3)))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onTapGesture { model.switchToSheet(index) }
            .contextMenu {
                Button {
                    sheetNameDraft = name
                    renamingSheetIndex = index
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    model.deleteSheet(at: index)
                } label: {
                    Label("Delete Sheet", systemImage: "trash")
                }
                .disabled(model.sheetNames.count <= 1)
            }
            .help(name)
    }

    private func toolButton(_ symbol: String, _ title: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(title)
    }

    private func toggleButton(_ symbol: String, _ title: String, isOn: Bool, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 20)
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(title)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("\(model.rowCount) row\(model.rowCount == 1 ? "" : "s") × \(model.columnCount) col\(model.columnCount == 1 ? "" : "s")")
            if !model.selectedRows.isEmpty {
                Text("\(model.selectedRows.count) selected")
            }
            Spacer()
            if model.isDirty {
                HStack(spacing: 3) {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                    Text("Unsaved")
                }
            }
            remoteSyncIndicator
            if model.isExcel {
                Text("Excel workbook · \(model.sheetNames.count) sheet\(model.sheetNames.count == 1 ? "" : "s")")
                Text("XLSX")
            } else {
                Text("\(model.delimiter.displayName)-separated")
                Text("UTF-8")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    @ViewBuilder
    private var remoteSyncIndicator: some View {
        if let link = model.remoteEdit {
            HStack(spacing: 3) {
                Image(systemName: remoteSyncSymbol)
                    .foregroundStyle(remoteSyncColor)
                Text(remoteSyncText)
            }
            .help("Editing a file on \(link.serverLabel). Saving uploads it back to \(link.remotePath).")
        }
    }

    private var remoteSyncSymbol: String {
        switch model.remoteSyncState {
        case .idle, .synced: return "checkmark.icloud"
        case .syncing:       return "arrow.clockwise.icloud"
        case .failed:        return "exclamationmark.icloud"
        }
    }

    private var remoteSyncColor: Color {
        switch model.remoteSyncState {
        case .idle, .synced: return .green
        case .syncing:       return .accentColor
        case .failed:        return .orange
        }
    }

    private var remoteSyncText: String {
        switch model.remoteSyncState {
        case .idle, .synced:  return "Synced to server"
        case .syncing:        return "Uploading…"
        case .failed(let m):  return m.isEmpty ? "Upload failed" : m
        }
    }
}

// MARK: - The native grid

/// Wraps an `NSTableView` (inside an `NSScrollView`) that renders the sheet:
/// a non‑editable row‑number gutter followed by one editable column per
/// `SpreadsheetModel.Column`. Cell edits, sorting, selection, and column
/// management flow through the `Coordinator`.
private struct SpreadsheetGridView: NSViewRepresentable {
    @ObservedObject var model: SpreadsheetModel

    static let gutterColumnID = "__spreadsheet_row_number__"

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        tableView.gridColor = .gridColor
        tableView.intercellSpacing = NSSize(width: 1, height: 2)
        tableView.rowHeight = 22
        tableView.usesAutomaticRowHeights = false
        tableView.style = .plain
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.tableDoubleClicked(_:))

        let header = SpreadsheetHeaderView()
        header.coordinator = context.coordinator
        tableView.headerView = header

        context.coordinator.tableView = tableView

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        context.coordinator.model = model
        context.coordinator.tableView = tableView
        context.coordinator.syncColumns(tableView)
        if context.coordinator.lastStructureRevision != model.structureRevision {
            context.coordinator.lastStructureRevision = model.structureRevision
            let selection = model.selectedRows
            tableView.reloadData()
            let valid = selection.filteredIndexSet { $0 < model.rowCount }
            tableView.selectRowIndexes(valid, byExtendingSelection: false)
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var model: SpreadsheetModel
        weak var tableView: NSTableView?
        var lastColumnSignature = ""
        var lastStructureRevision = -1

        init(model: SpreadsheetModel) { self.model = model }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { model.rowCount }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            let id = tableColumn.identifier.rawValue

            if id == SpreadsheetGridView.gutterColumnID {
                let cell = makeOrReuse(tableView, id: "__gutter__")
                let tf = cell.textField!
                tf.stringValue = "\(row + 1)"
                tf.isEditable = false
                tf.isSelectable = false
                tf.alignment = .right
                tf.textColor = .secondaryLabelColor
                tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                tf.delegate = nil
                return cell
            }

            guard let colUUID = UUID(uuidString: id) else { return nil }
            let cell = makeOrReuse(tableView, id: "__cell__")
            let tf = cell.textField!
            tf.stringValue = model.cell(rowIndex: row, columnID: colUUID)
            tf.isEditable = true
            tf.isSelectable = true
            tf.alignment = .left
            tf.textColor = .labelColor
            tf.font = .systemFont(ofSize: 12)
            tf.delegate = self
            return cell
        }

        private func makeOrReuse(_ tableView: NSTableView, id: String) -> NSTableCellView {
            let ident = NSUserInterfaceItemIdentifier(id)
            if let reused = tableView.makeView(withIdentifier: ident, owner: nil) as? NSTableCellView {
                return reused
            }
            let cell = NSTableCellView()
            cell.identifier = ident
            let tf = NSTextField()
            tf.isBordered = false
            tf.drawsBackground = false
            tf.focusRingType = .none
            tf.lineBreakMode = .byTruncatingTail
            tf.cell?.usesSingleLineMode = true
            tf.cell?.wraps = false
            tf.cell?.isScrollable = true
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        // MARK: Editing

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField, let tableView else { return }
            let row = tableView.row(for: tf)
            let colIndex = tableView.column(for: tf)
            guard row >= 0, colIndex >= 0 else { return }
            let tableColumn = tableView.tableColumns[colIndex]
            guard let colUUID = UUID(uuidString: tableColumn.identifier.rawValue) else { return }
            model.setCell(rowIndex: row, columnID: colUUID, value: tf.stringValue)
        }

        // MARK: Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            let indexes = tableView.selectedRowIndexes
            if indexes != model.selectedRows {
                DispatchQueue.main.async { [weak self] in self?.model.selectedRows = indexes }
            }
        }

        // MARK: Sorting

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let desc = tableView.sortDescriptors.first,
                  let key = desc.key, let colUUID = UUID(uuidString: key) else { return }
            model.sortRows(byColumnID: colUUID, ascending: desc.ascending)
        }

        // MARK: Double-click to edit

        @objc func tableDoubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            let col = sender.clickedColumn
            guard row >= 0, col > 0 else { return }   // col 0 is the gutter
            sender.editColumn(col, row: row, with: nil, select: true)
        }

        // MARK: Columns

        /// Rebuild the table's columns when the sheet's columns change; when only
        /// the names changed, refresh titles in place so widths are preserved.
        func syncColumns(_ tableView: NSTableView) {
            let sig = model.columnSignature
            if sig == lastColumnSignature { return }

            let dataColumns = tableView.tableColumns.filter {
                $0.identifier.rawValue != SpreadsheetGridView.gutterColumnID
            }
            let currentIDs = dataColumns.map { $0.identifier.rawValue }
            let modelIDs = model.columns.map { $0.id.uuidString }

            if !currentIDs.isEmpty, currentIDs == modelIDs {
                // Same columns, different names → just relabel.
                for tc in dataColumns {
                    if let col = model.columns.first(where: { $0.id.uuidString == tc.identifier.rawValue }) {
                        tc.title = col.name
                    }
                }
                lastColumnSignature = sig
                return
            }

            // Full rebuild.
            for col in tableView.tableColumns { tableView.removeTableColumn(col) }

            let gutter = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(SpreadsheetGridView.gutterColumnID))
            gutter.title = ""
            gutter.width = 48
            gutter.minWidth = 34
            gutter.maxWidth = 90
            gutter.resizingMask = .userResizingMask
            tableView.addTableColumn(gutter)

            for col in model.columns {
                let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.id.uuidString))
                tc.title = col.name
                tc.width = 140
                tc.minWidth = 44
                tc.resizingMask = .userResizingMask
                tc.sortDescriptorPrototype = NSSortDescriptor(key: col.id.uuidString, ascending: true)
                tableView.addTableColumn(tc)
            }
            lastColumnSignature = sig
        }

        // MARK: Header menu

        func headerMenu(forColumnIndex colIndex: Int) -> NSMenu? {
            let dataIndex = colIndex - 1   // account for the gutter at 0
            guard model.columns.indices.contains(dataIndex) else { return nil }
            let menu = NSMenu()
            func add(_ title: String, _ selector: Selector) {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                item.target = self
                item.representedObject = dataIndex
                menu.addItem(item)
            }
            add("Rename Column…", #selector(renameColumnAction(_:)))
            menu.addItem(.separator())
            add("Sort Ascending", #selector(sortAscAction(_:)))
            add("Sort Descending", #selector(sortDescAction(_:)))
            menu.addItem(.separator())
            add("Insert Column Left", #selector(insertLeftAction(_:)))
            add("Insert Column Right", #selector(insertRightAction(_:)))
            add("Delete Column", #selector(deleteColumnAction(_:)))
            return menu
        }

        @objc private func renameColumnAction(_ sender: NSMenuItem) {
            guard let idx = sender.representedObject as? Int,
                  model.columns.indices.contains(idx) else { return }
            let alert = NSAlert()
            alert.messageText = "Rename Column"
            alert.informativeText = "Enter a new name for this column."
            alert.addButton(withTitle: "Rename")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.stringValue = model.columns[idx].name
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            if alert.runModal() == .alertFirstButtonReturn {
                model.renameColumn(at: idx, to: field.stringValue)
            }
        }

        @objc private func sortAscAction(_ sender: NSMenuItem) {
            guard let idx = sender.representedObject as? Int,
                  model.columns.indices.contains(idx) else { return }
            model.sortRows(byColumnID: model.columns[idx].id, ascending: true)
        }

        @objc private func sortDescAction(_ sender: NSMenuItem) {
            guard let idx = sender.representedObject as? Int,
                  model.columns.indices.contains(idx) else { return }
            model.sortRows(byColumnID: model.columns[idx].id, ascending: false)
        }

        @objc private func insertLeftAction(_ sender: NSMenuItem) {
            guard let idx = sender.representedObject as? Int else { return }
            model.addColumn(at: idx)
        }

        @objc private func insertRightAction(_ sender: NSMenuItem) {
            guard let idx = sender.representedObject as? Int else { return }
            model.addColumn(at: idx + 1)
        }

        @objc private func deleteColumnAction(_ sender: NSMenuItem) {
            guard let idx = sender.representedObject as? Int else { return }
            model.deleteColumn(at: idx)
        }
    }
}

/// A table header that shows a per‑column context menu (rename / sort / insert /
/// delete) on right‑click.
private final class SpreadsheetHeaderView: NSTableHeaderView {
    weak var coordinator: SpreadsheetGridView.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let colIndex = column(at: point)
        guard colIndex >= 0 else { return nil }
        return coordinator?.headerMenu(forColumnIndex: colIndex)
    }
}
