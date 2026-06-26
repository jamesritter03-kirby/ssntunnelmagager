import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A graphical, drag-and-drop file browser for an `.sftp` session, backed by
/// `SFTPClient`. Drop files from Finder to upload; double-click a folder to open
/// it or a file to download; use the toolbar for the rest.
struct SFTPBrowserView: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var client: SFTPClient
    @EnvironmentObject var sessions: TerminalSessionManager

    /// F5 (NSF5FunctionKey) — the conventional “refresh” key.
    private static let f5Key = KeyEquivalent(Character(UnicodeScalar(0xF708)!))

    @State private var selection: Set<String> = []
    @State private var selectionAnchor: String?
    @State private var lastClickID: String?
    @State private var lastClickTime: Date = .distantPast
    @State private var isDropTargeted = false
    /// The id of the folder row a drag is currently hovering over (drop‑into).
    @State private var dropTargetFolder: String?
    @State private var showLog = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: SFTPEntry?
    @State private var renameText = ""

    init(session: TerminalSession) {
        _session = ObservedObject(initialValue: session)
        _client = ObservedObject(initialValue: session.sftpClient ?? SFTPClient(
            executable: "/usr/bin/sftp", args: [], profileID: nil,
            autofillPassword: false, requireAuthForPassword: false))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Group {
                switch client.phase {
                case .ready, .busy:        browser
                case .failed(let message): statusScreen(icon: "exclamationmark.triangle.fill",
                                                         tint: .orange, title: "Couldn’t connect",
                                                         message: message, showReconnect: true)
                case .ended:               statusScreen(icon: "bolt.horizontal.circle.fill",
                                                         tint: .secondary, title: "Disconnected",
                                                         message: "The SFTP session ended.",
                                                         showReconnect: true)
                case .connecting, .idle:   connectingScreen
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(refreshShortcut)
        .sheet(isPresented: $showLog) { logSheet }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { client.makeDirectory(newFolderName); newFolderName = "" }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        } message: {
            Text("Create a new folder in \(client.currentPath).")
        }
        .alert("Rename", isPresented: renameBinding) {
            TextField("New name", text: $renameText)
            Button("Rename") {
                if let t = renameTarget { client.rename(t, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { client.goUp() } label: { Image(systemName: "chevron.up") }
                .help("Go up one folder")
                .disabled(!client.isConnected)

            pathMenu

            Spacer(minLength: 8)

            Button { client.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh").disabled(!client.isConnected)
            Button { showNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                .help("New folder").disabled(!client.isConnected)
            Button { chooseAndUpload() } label: { Image(systemName: "arrow.up.doc") }
                .help("Upload files or folders…").disabled(!client.isConnected)
            Button { client.download(selectedEntries) } label: { Image(systemName: "arrow.down.doc") }
                .help("Download selected (⌘- or ⇧-click to select several)")
                .disabled(selectedEntries.isEmpty)
            Button(role: .destructive) { confirmDelete(selectedEntries) } label: { Image(systemName: "trash") }
                .help("Delete selected").disabled(selectedEntries.isEmpty)

            if client.isBusy {
                ProgressView().controlSize(.small).padding(.leading, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .buttonStyle(.borderless)
        .background(.bar)
    }

    private var pathMenu: some View {
        Menu {
            ForEach(ancestorPaths, id: \.self) { path in
                Button(path) { client.changeDirectory(to: path) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                Text(client.currentPath.isEmpty ? "Loading…" : client.currentPath)
                    .lineLimit(1).truncationMode(.head)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Jump to a parent folder")
        .disabled(!client.isConnected)
    }

    /// Cumulative ancestor paths of `currentPath`, deepest last.
    private var ancestorPaths: [String] {
        let path = client.currentPath
        guard path.hasPrefix("/") else { return path.isEmpty ? [] : [path] }
        let parts = path.split(separator: "/").map(String.init)
        var result = ["/"]
        var acc = ""
        for part in parts {
            acc += "/" + part
            result.append(acc)
        }
        return result
    }

    // MARK: - Browser

    private var browser: some View {
        ZStack {
            List(selection: $selection) {
                ForEach(client.entries) { entry in
                    entryRow(entry)
                }
            }
            .listStyle(.inset)
            // Let the Delete key remove whatever is selected (one row or many).
            .onDeleteCommand { confirmDelete(selectedEntries) }
            // Right-click in empty space → folder-wide actions (incl. Refresh).
            .contextMenu { listBackgroundMenu }

            if client.entries.isEmpty && !client.isBusy {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("This folder is empty").foregroundStyle(.secondary)
                    Text("Drag files here to upload").font(.caption).foregroundStyle(.tertiary)
                }
            }

            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08).clipShape(RoundedRectangle(cornerRadius: 10)))
                    .overlay(
                        Label("Drop to upload to \(client.currentPath)", systemImage: "arrow.down.doc.fill")
                            .font(.title3.weight(.semibold))
                            .padding(14)
                            .background(.regularMaterial, in: Capsule())
                    )
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    /// One file/folder row. Folder rows also act as a drop target so a drag can
    /// upload straight **into** that folder; other rows fall through to the
    /// whole‑list drop (upload to the current folder).
    @ViewBuilder
    private func entryRow(_ entry: SFTPEntry) -> some View {
        let row = SFTPRow(entry: entry, isDropTarget: dropTargetFolder == entry.id)
            .tag(entry.id)
            // Make the whole row (text included) one hit target, then drive
            // selection ourselves: once a row carries tap gestures, List's own
            // single-click selection stops firing, so we replicate it here —
            // plain click selects, ⌘-click toggles, ⇧-click extends a range.
            .contentShape(Rectangle())
            // One tap gesture only, so a single click selects instantly. A
            // double-click is detected manually inside selectOnClick via the
            // system double-click interval — pairing count:1 and count:2 tap
            // gestures makes SwiftUI delay every single click (felt sluggish).
            .onTapGesture { selectOnClick(entry) }
            .contextMenu { rowMenu(entry) }
        if entry.isDirectory {
            row.onDrop(of: [UTType.fileURL],
                       isTargeted: folderTargetBinding(entry)) { providers in
                handleDrop(providers, into: entry)
            }
        } else {
            row
        }
    }

    private func folderTargetBinding(_ entry: SFTPEntry) -> Binding<Bool> {
        Binding(
            get: { dropTargetFolder == entry.id },
            set: { targeted in
                if targeted { dropTargetFolder = entry.id }
                else if dropTargetFolder == entry.id { dropTargetFolder = nil }
            })
    }

    @ViewBuilder
    private func rowMenu(_ entry: SFTPEntry) -> some View {
        // If the right-clicked row is part of a multi-row selection, act on the
        // whole selection; otherwise just this one row.
        let targets = (selection.contains(entry.id) && selectedEntries.count > 1)
            ? selectedEntries : [entry]
        if targets.count == 1, entry.isDirectory || entry.kind == .symlink {
            Button("Open") { client.open(entry) }
        }
        Button(targets.count > 1 ? "Download \(targets.count) Items" : "Download") {
            client.download(targets)
        }
        if targets.count == 1 {
            Button("Rename…") { renameText = entry.name; renameTarget = entry }
        }
        Divider()
        Button(targets.count > 1 ? "Delete \(targets.count) Items" : "Delete",
               role: .destructive) { confirmDelete(targets) }
        Divider()
        Button { client.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
    }

    // MARK: - State screens

    private var connectingScreen: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(client.statusMessage.isEmpty ? "Connecting…" : client.statusMessage)
                .foregroundStyle(.secondary)
            Button("Show Log") { showLog = true }
                .buttonStyle(.link)
        }
    }

    private func statusScreen(icon: String, tint: Color, title: String,
                              message: String, showReconnect: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 42)).foregroundStyle(tint)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 12) {
                if showReconnect {
                    Button { session.restart() } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Show Log") { showLog = true }
            }
        }
        .padding()
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(client.statusMessage)
                .font(.caption)
                .foregroundStyle(client.errorMessage != nil ? Color.red : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text("Save to:").font(.caption).foregroundStyle(.secondary)
            Button(client.localDownloadDirectory.lastPathComponent) { chooseDownloadFolder() }
                .buttonStyle(.link)
                .font(.caption)
                .help(client.localDownloadDirectory.path)
            Divider().frame(height: 14)
            Button { showLog = true } label: { Image(systemName: "doc.plaintext") }
                .buttonStyle(.borderless)
                .help("Show the raw sftp log")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var logSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SFTP Log").font(.headline)
                Spacer()
                Button("Done") { showLog = false }
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(client.transcript.isEmpty ? "No output yet." : client.transcript)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(width: 560, height: 420)
    }

    // MARK: - Helpers

    private var selectedEntries: [SFTPEntry] {
        client.entries.filter { selection.contains($0.id) }
    }

    /// Replicates a List row's native single-click selection (suppressed once a
    /// row carries tap gestures): plain click selects just this row, ⌘-click
    /// toggles it, ⇧-click extends a contiguous range from the last anchor. A
    /// quick second click on the same row opens it — detected here via the system
    /// double-click interval so we can use just one (instant) tap gesture.
    private func selectOnClick(_ entry: SFTPEntry) {
        let id = entry.id
        let flags = NSEvent.modifierFlags
        let plain = !flags.contains(.command) && !flags.contains(.shift)
        if plain, lastClickID == id,
           Date().timeIntervalSince(lastClickTime) < NSEvent.doubleClickInterval {
            lastClickTime = .distantPast   // don't let a third click re-trigger
            client.open(entry)
            return
        }
        lastClickTime = Date()
        lastClickID = id

        let ids = client.entries.map(\.id)
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

    private var statusColor: Color {
        switch client.phase {
        case .ready, .busy: return .green
        case .connecting, .idle: return .yellow
        case .failed: return .red
        case .ended: return .secondary
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    /// Folder-wide actions for the empty-area right-click menu.
    @ViewBuilder
    private var listBackgroundMenu: some View {
        Button { client.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            .disabled(!client.isConnected)
        Button { showNewFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
            .disabled(!client.isConnected)
        Button { chooseAndUpload() } label: { Label("Upload…", systemImage: "arrow.up.doc") }
            .disabled(!client.isConnected)
    }

    /// An invisible button binding F5 to Refresh, active only on the selected tab
    /// (every tab stays mounted, so gating avoids duplicate-shortcut ambiguity).
    private var refreshShortcut: some View {
        Button("") { if client.isConnected { client.refresh() } }
            .keyboardShortcut(Self.f5Key, modifiers: [])
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
            .disabled(sessions.selectedSessionID != session.id)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard client.isConnected else { return false }
        loadFileURLs(from: providers) { urls in
            if !urls.isEmpty { client.upload(urls) }
        }
        return true
    }

    /// Drop onto a folder row — upload into that folder.
    private func handleDrop(_ providers: [NSItemProvider], into folder: SFTPEntry) -> Bool {
        guard client.isConnected, folder.isDirectory else { return false }
        dropTargetFolder = nil
        loadFileURLs(from: providers) { urls in
            if !urls.isEmpty { client.upload(urls, into: folder.name) }
        }
        return true
    }

    /// Resolve the file URLs from a set of drag providers, on the main queue.
    private func loadFileURLs(from providers: [NSItemProvider],
                             completion: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                if let url = object as? URL { urls.append(url) }
                else if let nsurl = object as? NSURL { urls.append(nsurl as URL) }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls.filter { $0.isFileURL }) }
    }

    private func chooseAndUpload() {
        let panel = NSOpenPanel()
        panel.title = "Upload to \(client.currentPath)"
        panel.message = "Choose file(s) or folder(s) to upload."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        if panel.runModal() == .OK { client.upload(panel.urls) }
    }

    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.title = "Download Folder"
        panel.message = "Choose where downloaded files are saved."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = client.localDownloadDirectory
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.urls.first {
            client.localDownloadDirectory = url
        }
    }

    private func confirmDelete(_ entries: [SFTPEntry]) {
        guard !entries.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if entries.count == 1 {
            alert.messageText = "Delete “\(entries[0].name)”?"
        } else {
            alert.messageText = "Delete \(entries.count) items?"
        }
        alert.informativeText = "This permanently removes the item(s) on the server."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            for entry in entries { client.remove(entry) }
            selection.removeAll()
        }
    }
}

/// One row in the SFTP browser list.
private struct SFTPRow: View {
    let entry: SFTPEntry
    var isDropTarget: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.systemImage)
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).lineLimit(1)
                if entry.kind == .symlink, let target = entry.symlinkTarget {
                    Text("→ \(target)")
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(entry.displaySize)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
            Text(entry.modified)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 116, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(isDropTarget ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
    }
}
