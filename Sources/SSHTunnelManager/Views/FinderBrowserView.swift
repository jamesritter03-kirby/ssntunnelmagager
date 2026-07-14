import SwiftUI
import AppKit

/// One entry in a local directory listing (built from `URLResourceValues`).
struct LocalFileEntry: Identifiable, Hashable {
    enum Kind { case directory, file, symlink }

    let url: URL
    let name: String
    let kind: Kind
    let size: Int64
    let modified: Date?

    var id: String { url.path }
    var isDirectory: Bool { kind == .directory }

    init(url: URL, keys: Set<URLResourceKey>) {
        self.url = url
        self.name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: keys)
        if values?.isSymbolicLink == true {
            self.kind = .symlink
        } else if values?.isDirectory == true {
            self.kind = .directory
        } else {
            self.kind = .file
        }
        self.size = Int64(values?.fileSize ?? 0)
        self.modified = values?.contentModificationDate
    }

    var systemImage: String {
        switch kind {
        case .directory: return "folder.fill"
        case .symlink:   return "arrowshape.turn.up.right.circle.fill"
        case .file:      return "doc.fill"
        }
    }

    /// Human-readable size (files only).
    var displaySize: String {
        guard kind != .directory else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var displayModified: String {
        guard let modified else { return "" }
        return LocalFileEntry.dateFormatter.string(from: modified)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

/// How a Finder tab's listing is ordered.
enum FileSortField: String, CaseIterable, Identifiable {
    case name, size, modified, kind
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name:     return "Name"
        case .size:     return "Size"
        case .modified: return "Date Modified"
        case .kind:     return "Kind"
        }
    }
    var systemImage: String {
        switch self {
        case .name:     return "textformat"
        case .size:     return "externaldrive"
        case .modified: return "calendar"
        case .kind:     return "doc.on.doc"
        }
    }
}

/// Which items a Finder tab shows.
enum FileKindFilter: String, CaseIterable, Identifiable {
    case all, folders, files
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all:     return "All Items"
        case .folders: return "Folders Only"
        case .files:   return "Files Only"
        }
    }
    var systemImage: String {
        switch self {
        case .all:     return "square.grid.2x2"
        case .folders: return "folder"
        case .files:   return "doc"
        }
    }
}

/// Backs the local "Finder" file-browser tab. Lists a directory on this Mac and
/// supports navigating, opening, revealing in Finder, making folders and moving
/// items to the Trash. Rows are draggable as file URLs, so the user can drag a
/// file onto a terminal (to paste its path) or onto an SFTP tab (to upload it).
final class LocalFileBrowser: ObservableObject {
    @Published private(set) var currentURL: URL
    /// The full, unfiltered listing of the current folder (the disk read result).
    @Published private(set) var allEntries: [LocalFileEntry] = []
    /// The rows actually shown: `allEntries` after the active filter, then sort.
    @Published private(set) var entries: [LocalFileEntry] = []
    @Published var showHidden = false { didSet { reload() } }
    @Published var errorMessage: String?

    // Sort + filter options. Changing any of these re-derives `entries` from the
    // already-loaded `allEntries`, so no extra disk read is needed.
    @Published var sortField: FileSortField = .name { didSet { applyView() } }
    @Published var sortAscending = true { didSet { applyView() } }
    @Published var foldersFirst = true { didSet { applyView() } }
    @Published var kindFilter: FileKindFilter = .all { didSet { applyView() } }
    @Published var filterText = "" { didSet { applyView() } }

    /// Fires when the browsed folder changes, so the owning tab can retitle itself.
    var onPathChange: ((URL) -> Void)?

    var currentPath: String { currentURL.path }

    private let resourceKeys: Set<URLResourceKey> =
        [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]

    /// Drives the live auto-refresh: a low-frequency timer re-reads the current
    /// folder and republishes only when a cheap content signature changes, so
    /// files added, removed or edited by other apps appear on their own without
    /// a manual Refresh.
    private var refreshTimer: Timer?
    private var folderSignature: Int = 0

    init(startPath: String?) {
        let fm = FileManager.default
        if let raw = startPath?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                currentURL = URL(fileURLWithPath: expanded, isDirectory: true)
            } else {
                currentURL = fm.homeDirectoryForCurrentUser
            }
        } else {
            currentURL = fm.homeDirectoryForCurrentUser
        }
        listContents()
        startAutoRefresh()
    }

    deinit { stopAutoRefresh() }

    // MARK: - Navigation

    func reload() { listContents() }

    func go(to url: URL) { navigate(to: url) }

    func goUp() {
        let parent = currentURL.deletingLastPathComponent()
        if parent.path != currentURL.path { navigate(to: parent) }
    }

    func goHome() { navigate(to: FileManager.default.homeDirectoryForCurrentUser) }

    /// Cumulative ancestor URLs of `currentURL`, root first, current last.
    var ancestors: [URL] {
        var result: [URL] = []
        var url = currentURL.standardizedFileURL
        result.append(url)
        while url.path != "/" {
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            result.insert(parent, at: 0)
            url = parent
        }
        return result
    }

    private func navigate(to url: URL) {
        currentURL = url.standardizedFileURL
        errorMessage = nil
        listContents()
        onPathChange?(currentURL)
    }

    // MARK: - Actions

    func open(_ entry: LocalFileEntry) {
        if entry.isDirectory {
            navigate(to: entry.url)
            return
        }
        if entry.kind == .symlink {
            let resolved = entry.url.resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir),
               isDir.boolValue {
                navigate(to: resolved)
                return
            }
        }
        NSWorkspace.shared.open(entry.url)
    }

    /// Reveal the given items (or the current folder) in the macOS Finder.
    func revealInFinder(_ items: [LocalFileEntry]) {
        let urls = items.map(\.url)
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [currentURL] : urls)
    }

    func newFolder(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let dest = currentURL.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveToTrash(_ items: [LocalFileEntry]) {
        for item in items {
            do { try FileManager.default.trashItem(at: item.url, resultingItemURL: nil) }
            catch { errorMessage = error.localizedDescription }
        }
        reload()
    }

    // MARK: - View options

    /// Whether a name or kind filter is currently narrowing the listing.
    var hasActiveFilter: Bool {
        kindFilter != .all || !filterText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Reset both the text and kind filters (keeps the chosen sort).
    func clearFilter() {
        filterText = ""
        kindFilter = .all
    }

    // MARK: - Listing

    private func listContents() {
        do {
            allEntries = try readCurrentFolder()
            errorMessage = nil
        } catch {
            allEntries = []
            errorMessage = error.localizedDescription
        }
        folderSignature = LocalFileBrowser.signature(of: allEntries)
        applyView()
    }

    /// One disk read of the current folder, mapped to entries. Shared by the
    /// initial/manual listing and the auto-refresh poll so both observe the
    /// exact same values (and therefore compute matching content signatures).
    private func readCurrentFolder() throws -> [LocalFileEntry] {
        let fm = FileManager.default
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        let urls = try fm.contentsOfDirectory(at: currentURL,
                                              includingPropertiesForKeys: Array(resourceKeys),
                                              options: options)
        return urls.map { LocalFileEntry(url: $0, keys: resourceKeys) }
    }

    // MARK: - Live auto-refresh

    /// Start (or restart) the background folder watch. The timer runs in the
    /// common run-loop modes so it keeps firing during menus and scrolling, and
    /// reads whatever `currentURL` points at each tick — so it transparently
    /// follows navigation without needing a restart.
    private func startAutoRefresh() {
        stopAutoRefresh()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollForExternalChanges()
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Re-read the current folder and republish only if its content signature
    /// changed. Folders we currently can't read are left to a manual retry, and
    /// an unchanged folder never touches published state — so an idle tab stays
    /// completely quiet.
    private func pollForExternalChanges() {
        guard errorMessage == nil, let fresh = try? readCurrentFolder() else { return }
        let signature = LocalFileBrowser.signature(of: fresh)
        guard signature != folderSignature else { return }
        allEntries = fresh
        folderSignature = signature
        applyView()
    }

    /// A cheap, order-independent fingerprint of a folder's contents — each
    /// item's name, size and modified date. Additions, removals, renames and
    /// in-place edits (which don't change the folder's own timestamp) all
    /// produce a different value.
    private static func signature(of entries: [LocalFileEntry]) -> Int {
        var hasher = Hasher()
        for entry in entries.sorted(by: { $0.name < $1.name }) {
            hasher.combine(entry.name)
            hasher.combine(entry.size)
            hasher.combine(entry.modified ?? .distantPast)
        }
        return hasher.finalize()
    }

    /// Re-derive the visible `entries` by applying the active filter and sort to
    /// `allEntries`. Purely in-memory, so it runs on every view-option change
    /// without touching the disk again.
    private func applyView() {
        var result = allEntries

        switch kindFilter {
        case .all:     break
        case .folders: result = result.filter { $0.isDirectory }
        case .files:   result = result.filter { !$0.isDirectory }
        }

        let needle = filterText.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(needle) }
        }

        result.sort { a, b in
            // Keep folders grouped above files when asked, regardless of direction.
            if foldersFirst && a.isDirectory != b.isDirectory { return a.isDirectory }
            return sortAscending
                ? LocalFileBrowser.precedes(a, b, by: sortField)
                : LocalFileBrowser.precedes(b, a, by: sortField)
        }
        entries = result
    }

    /// Ascending ordering of two entries by a field; ties fall back to a natural
    /// name compare so the order stays stable.
    private static func precedes(_ a: LocalFileEntry, _ b: LocalFileEntry,
                                 by field: FileSortField) -> Bool {
        func byName() -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        switch field {
        case .name:
            return byName()
        case .size:
            return a.size == b.size ? byName() : a.size < b.size
        case .modified:
            let da = a.modified ?? .distantPast
            let db = b.modified ?? .distantPast
            return da == db ? byName() : da < db
        case .kind:
            let ea = a.url.pathExtension.lowercased()
            let eb = b.url.pathExtension.lowercased()
            return ea == eb ? byName()
                            : ea.localizedStandardCompare(eb) == .orderedAscending
        }
    }
}

/// A local file browser tab. Mirrors the SFTP browser, but for files on this Mac.
/// Drag a row onto a terminal to paste its path, or onto an SFTP tab to upload it.
struct FinderBrowserView: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var browser: LocalFileBrowser
    @EnvironmentObject var sessions: TerminalSessionManager

    @State private var selection: Set<String> = []
    @State private var selectionAnchor: String?
    @State private var lastClickID: String?
    @State private var lastClickTime: Date = .distantPast
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    /// Live width of the listing area. When the tab is docked to a narrow side
    /// panel we drop the fixed-width Size / Date columns so the Name column keeps
    /// the space and is the one that grows and shrinks as the dock is resized.
    @State private var contentWidth: CGFloat = 0

    /// Show the Date Modified column only when there's comfortable room.
    private var showDateColumn: Bool { contentWidth >= 340 }
    /// Show the Size column until the panel gets quite narrow.
    private var showSizeColumn: Bool { contentWidth >= 240 }

    init(session: TerminalSession) {
        _session = ObservedObject(initialValue: session)
        _browser = ObservedObject(initialValue: session.finderModel
                                  ?? LocalFileBrowser(startPath: nil))
    }

    var body: some View {
        // Pin the whole listing to the container's exact width. A SwiftUI List is
        // backed by an NSTableView that keeps a minimum intrinsic width, so in a
        // narrow docked drawer the fixed Size / Date columns would otherwise push
        // the content wider than the pane and get clipped. Forcing the width makes
        // the content shrink to fit, and `contentWidth` is then the true pane
        // width that drives which columns stay visible (Name always wins).
        GeometryReader { proxy in
            VStack(spacing: 0) {
                toolbar
                Divider()
                listHeader
                Divider()
                browserList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                statusBar
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .onAppear { contentWidth = proxy.size.width }
            .onChange(of: proxy.size.width) { newValue in contentWidth = newValue }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { browser.newFolder(named: newFolderName); newFolderName = "" }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        } message: {
            Text("Create a new folder in \(browser.currentPath).")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { browser.goUp() } label: { Image(systemName: "chevron.up") }
                .help("Go up one folder")
            Button { browser.goHome() } label: { Image(systemName: "house") }
                .help("Go to your home folder")

            pathMenu

            Spacer(minLength: 8)

            filterField
            viewOptionsMenu

            Divider().frame(height: 16)

            Button { browser.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
            Button { showNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                .help("New folder")
            Button { browser.showHidden.toggle() } label: {
                Image(systemName: browser.showHidden ? "eye.slash" : "eye")
            }
            .help(browser.showHidden ? "Hide hidden files" : "Show hidden files")
            Button { browser.revealInFinder(selectedEntries) } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .buttonStyle(.borderless)
        .background(.bar)
    }

    /// Inline name filter. Typing narrows the listing live; the x clears it.
    private var filterField: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.caption)
                .foregroundStyle(browser.hasActiveFilter ? Color.accentColor : Color.secondary)
            TextField("Filter", text: $browser.filterText)
                .textFieldStyle(.plain)
                .frame(width: 92)
            if !browser.filterText.isEmpty {
                Button { browser.filterText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear filter")
            }
        }
        .font(.callout)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: Capsule())
        .overlay(Capsule().strokeBorder(.secondary.opacity(0.25)))
        .help("Filter items in this folder by name")
    }

    /// Sort field/direction plus a kind filter, all in one popover menu.
    private var viewOptionsMenu: some View {
        Menu {
            Section("Sort By") {
                Picker("Sort By", selection: $browser.sortField) {
                    ForEach(FileSortField.allCases) { field in
                        Label(field.title, systemImage: field.systemImage).tag(field)
                    }
                }
                .pickerStyle(.inline)
                Picker("Order", selection: $browser.sortAscending) {
                    Label("Ascending", systemImage: "arrow.up").tag(true)
                    Label("Descending", systemImage: "arrow.down").tag(false)
                }
                .pickerStyle(.inline)
                Toggle("Keep Folders on Top", isOn: $browser.foldersFirst)
            }
            Section("Show") {
                Picker("Show", selection: $browser.kindFilter) {
                    ForEach(FileKindFilter.allCases) { f in
                        Label(f.title, systemImage: f.systemImage).tag(f)
                    }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort and filter")
    }

    private var pathMenu: some View {
        Menu {
            ForEach(browser.ancestors, id: \.self) { url in
                Button(url.path == "/" ? "/" : url.lastPathComponent) { browser.go(to: url) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                Text(browser.currentPath)
                    .lineLimit(1).truncationMode(.head)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Jump to a parent folder")
    }

    // MARK: - List

    /// Clickable column header. Clicking a column sorts by it; clicking the
    /// active column again flips the direction. Widths match `FinderRow`.
    private var listHeader: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 18, height: 1)
            sortHeader("Name", field: .name, alignment: .leading)
                .frame(maxWidth: .infinity)
            if showSizeColumn {
                sortHeader("Size", field: .size, alignment: .trailing)
                    .frame(width: 76)
            }
            if showDateColumn {
                sortHeader("Date Modified", field: .modified, alignment: .trailing)
                    .frame(width: 132)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func sortHeader(_ title: String, field: FileSortField,
                            alignment: Alignment) -> some View {
        Button {
            if browser.sortField == field {
                browser.sortAscending.toggle()
            } else {
                browser.sortField = field
                browser.sortAscending = true
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: browser.sortAscending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(browser.sortField == field ? 1 : 0)
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(title.lowercased())")
    }

    private var emptyMessage: String {
        if let error = browser.errorMessage { return error }
        if browser.hasActiveFilter { return "No items match your filter" }
        return "This folder is empty"
    }

    private var browserList: some View {
        ZStack {
            List(selection: $selection) {
                ForEach(browser.entries) { entry in
                    FinderRow(entry: entry, showSize: showSizeColumn, showDate: showDateColumn)
                        .tag(entry.id)
                        .listRowInsets(EdgeInsets())
                        // Make the whole row (text included) one hit target, then
                        // drive selection ourselves: once a row carries tap/drag
                        // gestures, List's own single-click selection stops firing,
                        // so we replicate it here — plain click selects, ⌘-click
                        // toggles, ⇧-click extends a range.
                        .contentShape(Rectangle())
                        // One tap gesture only, so a single click selects
                        // instantly. A double-click is detected manually inside
                        // selectOnClick via the system double-click interval —
                        // pairing count:1 and count:2 tap gestures makes SwiftUI
                        // delay every single click (which felt sluggish).
                        .onTapGesture { selectOnClick(entry) }
                        .onDrag {
                            // Vend the grabbed file URL (public.file-url) so it can
                            // be dropped onto a terminal to paste its path, onto an
                            // SFTP tab to upload, or into the real Finder. SwiftUI's
                            // .onDrag can vend only ONE provider, so also record the
                            // whole selection: dragging a selected row drags them
                            // all (Finder behaviour), and an in-app SFTP drop expands
                            // the single pasteboard file back to the full set.
                            let dragURLs = (selection.contains(entry.id) && selectedEntries.count > 1)
                                ? selectedEntries.map(\.url)
                                : [entry.url]
                            InAppFileDrag.shared.begin(dragURLs)
                            return NSItemProvider(object: entry.url as NSURL)
                        }
                        .contextMenu { rowMenu(entry) }
                }
            }
            .listStyle(.plain)
            .onDeleteCommand { confirmTrash(selectedEntries) }

            if browser.entries.isEmpty {
                EmptyStateView(icon: browser.hasActiveFilter
                               ? "line.3.horizontal.decrease.circle"
                               : "folder",
                               title: emptyMessage) {
                    if browser.hasActiveFilter {
                        Button("Clear Filter") { browser.clearFilter() }
                            .buttonStyle(.link)
                    } else {
                        Text("Drag a file onto a terminal to paste its path")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ entry: LocalFileEntry) -> some View {
        let targets = (selection.contains(entry.id) && selectedEntries.count > 1)
            ? selectedEntries : [entry]
        let editableFiles = targets.filter { $0.kind == .file }
        if targets.count == 1 {
            Button {
                browser.open(entry)
            } label: {
                Label(entry.isDirectory ? "Open" : "Open with Default App",
                      systemImage: entry.isDirectory ? "folder" : "arrow.up.forward.app")
            }
        }
        if !editableFiles.isEmpty {
            Button {
                openInTextEditor(editableFiles)
            } label: {
                Label(editableFiles.count > 1
                      ? "Open \(editableFiles.count) Files in Text Editor"
                      : "Open in Text Editor", systemImage: "doc.text")
            }
        }
        if editableFiles.count == 1, let file = editableFiles.first {
            Button {
                sessions.openSpreadsheet(path: file.url.path)
            } label: {
                Label("Open as Spreadsheet", systemImage: "tablecells")
            }
        }
        Button { browser.revealInFinder(targets) } label: {
            Label("Reveal in Finder", systemImage: "magnifyingglass")
        }
        Button { copyPaths(targets) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        Divider()
        Button(role: .destructive) {
            confirmTrash(targets)
        } label: {
            Label(targets.count > 1 ? "Move \(targets.count) Items to Trash" : "Move to Trash",
                  systemImage: "trash")
        }
    }

    /// Open each of the given local files in its own built-in text-editor tab.
    private func openInTextEditor(_ files: [LocalFileEntry]) {
        for entry in files where entry.kind == .file {
            sessions.openTextEditor(path: entry.url.path)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive").foregroundStyle(.secondary).font(.caption)
            Text(itemCountText)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let error = browser.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var itemCountText: String {
        let shown = browser.entries.count
        let total = browser.allEntries.count
        let selected = selection.count
        if selected > 0 { return "\(selected) of \(shown) selected" }
        if shown != total { return "\(shown) of \(total) shown" }
        return "\(total) item\(total == 1 ? "" : "s")"
    }

    // MARK: - Helpers

    private var selectedEntries: [LocalFileEntry] {
        browser.entries.filter { selection.contains($0.id) }
    }

    /// Replicates a List row's native single-click selection (suppressed once a
    /// row carries tap/drag gestures): plain click selects just this row, ⌘-click
    /// toggles it, ⇧-click extends a contiguous range from the last anchor. A
    /// quick second click on the same row opens it — detected here via the system
    /// double-click interval so we can use just one (instant) tap gesture.
    private func selectOnClick(_ entry: LocalFileEntry) {
        let id = entry.id
        let flags = NSEvent.modifierFlags
        let plain = !flags.contains(.command) && !flags.contains(.shift)
        if plain, lastClickID == id,
           Date().timeIntervalSince(lastClickTime) < NSEvent.doubleClickInterval {
            lastClickTime = .distantPast   // don't let a third click re-trigger
            browser.open(entry)
            return
        }
        lastClickTime = Date()
        lastClickID = id

        let ids = browser.entries.map(\.id)
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            selectionAnchor = id
        } else if flags.contains(.shift), let anchor = selectionAnchor,
                  let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: id) {
            selection = Set(ids[min(a, b)...max(a, b)])
        } else {
            selection = [id]
            selectionAnchor = id
        }
    }

    private func copyPaths(_ entries: [LocalFileEntry]) {
        let text = entries.map(\.url.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func confirmTrash(_ entries: [LocalFileEntry]) {
        guard !entries.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = entries.count == 1
            ? "Move “\(entries[0].name)” to the Trash?"
            : "Move \(entries.count) items to the Trash?"
        alert.informativeText = "You can restore items from the Trash until it's emptied."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            browser.moveToTrash(entries)
            selection.removeAll()
        }
    }
}

/// One row in the local file browser list.
private struct FinderRow: View {
    let entry: LocalFileEntry
    var showSize = true
    var showDate = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.systemImage)
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showSize {
                Text(entry.displaySize)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)
            }
            if showDate {
                Text(entry.displayModified)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 132, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }
}
