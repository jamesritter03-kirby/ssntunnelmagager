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

/// Backs the local "Finder" file-browser tab. Lists a directory on this Mac and
/// supports navigating, opening, revealing in Finder, making folders and moving
/// items to the Trash. Rows are draggable as file URLs, so the user can drag a
/// file onto a terminal (to paste its path) or onto an SFTP tab (to upload it).
final class LocalFileBrowser: ObservableObject {
    @Published private(set) var currentURL: URL
    @Published private(set) var entries: [LocalFileEntry] = []
    @Published var showHidden = false { didSet { reload() } }
    @Published var errorMessage: String?

    /// Fires when the browsed folder changes, so the owning tab can retitle itself.
    var onPathChange: ((URL) -> Void)?

    var currentPath: String { currentURL.path }

    private let resourceKeys: Set<URLResourceKey> =
        [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]

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
    }

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

    // MARK: - Listing

    private func listContents() {
        let fm = FileManager.default
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        do {
            let urls = try fm.contentsOfDirectory(at: currentURL,
                                                  includingPropertiesForKeys: Array(resourceKeys),
                                                  options: options)
            entries = urls
                .map { LocalFileEntry(url: $0, keys: resourceKeys) }
                .sorted { a, b in
                    if a.isDirectory != b.isDirectory { return a.isDirectory }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
    }
}

/// A local file browser tab. Mirrors the SFTP browser, but for files on this Mac.
/// Drag a row onto a terminal to paste its path, or onto an SFTP tab to upload it.
struct FinderBrowserView: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var browser: LocalFileBrowser

    @State private var selection: Set<String> = []
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    init(session: TerminalSession) {
        _session = ObservedObject(initialValue: session)
        _browser = ObservedObject(initialValue: session.finderModel
                                  ?? LocalFileBrowser(startPath: nil))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            browserList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
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

    private var browserList: some View {
        ZStack {
            List(selection: $selection) {
                ForEach(browser.entries) { entry in
                    FinderRow(entry: entry)
                        .tag(entry.id)
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            browser.open(entry)
                        })
                        .onDrag {
                            // Vend the file URL (public.file-url) so it can be
                            // dropped onto a terminal to paste its path, onto an
                            // SFTP tab to upload, or into the real Finder.
                            NSItemProvider(object: entry.url as NSURL)
                        }
                        .contextMenu { rowMenu(entry) }
                }
            }
            .listStyle(.inset)
            .onDeleteCommand { confirmTrash(selectedEntries) }

            if browser.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text(browser.errorMessage ?? "This folder is empty")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Drag a file onto a terminal to paste its path")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ entry: LocalFileEntry) -> some View {
        let targets = (selection.contains(entry.id) && selectedEntries.count > 1)
            ? selectedEntries : [entry]
        if targets.count == 1 {
            Button(entry.isDirectory ? "Open" : "Open with Default App") { browser.open(entry) }
        }
        Button("Reveal in Finder") { browser.revealInFinder(targets) }
        Button("Copy Path") { copyPaths(targets) }
        Divider()
        Button(targets.count > 1 ? "Move \(targets.count) Items to Trash" : "Move to Trash",
               role: .destructive) { confirmTrash(targets) }
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
        let count = browser.entries.count
        let selected = selection.count
        if selected > 0 { return "\(selected) of \(count) selected" }
        return "\(count) item\(count == 1 ? "" : "s")"
    }

    // MARK: - Helpers

    private var selectedEntries: [LocalFileEntry] {
        browser.entries.filter { selection.contains($0.id) }
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.systemImage)
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            Text(entry.name).lineLimit(1)
            Spacer(minLength: 8)
            Text(entry.displaySize)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
            Text(entry.displayModified)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 132, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}
