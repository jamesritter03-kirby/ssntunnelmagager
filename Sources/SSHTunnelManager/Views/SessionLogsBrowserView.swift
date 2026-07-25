import SwiftUI
import AppKit

/// Presentation state for the **Saved Session Logs** browser sheet.
@MainActor
final class SessionLogsBrowserModel: ObservableObject {
    static let shared = SessionLogsBrowserModel()
    @Published var isPresented = false
    func present() { isPresented = true }
    private init() {}
}

/// One transcript log file on disk, with the metadata shown in the list.
private struct SavedLog: Identifiable {
    let url: URL
    var id: URL { url }
    let name: String
    let modified: Date
    let size: Int
}

/// Browse every saved terminal session log: preview its contents, then open,
/// reveal, share or delete it. Logs live in `TerminalSession.logsDirectory`.
struct SessionLogsBrowserView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var logs: [SavedLog] = []
    @State private var selection: URL?
    @State private var searchText = ""
    @State private var preview = ""
    @State private var confirmingDelete = false

    private var filtered: [SavedLog] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return logs }
        return logs.filter { $0.name.lowercased().contains(q) }
    }

    private var selectedLog: SavedLog? {
        logs.first { $0.url == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if logs.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    logList
                        .frame(width: 300)
                    Divider()
                    previewPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 460, idealHeight: 580)
        .onAppear(perform: reload)
        .onChange(of: selection) { _ in loadPreview() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            DialogHeader(
                icon: "doc.text.magnifyingglass",
                title: "Saved Session Logs",
                subtitle: "Browse, open, share or delete recorded terminal transcripts."
            )
            Spacer()
            Button {
                reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Rescan the logs folder")
        }
        .padding(16)
    }

    // MARK: - List

    private var logList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            List(selection: $selection) {
                ForEach(filtered) { log in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(log.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 6) {
                            Text(log.modified, format: .dateTime.year().month().day()
                                .hour().minute())
                            Text("·")
                            Text(byteString(log.size))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(log.url)
                    .contextMenu { rowMenu(for: log) }
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func rowMenu(for log: SavedLog) -> some View {
        Button {
            NSWorkspace.shared.open(log.url)
        } label: {
            Label("Open", systemImage: "doc.text")
        }
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([log.url])
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        ShareLink(item: log.url) {
            Label("Share…", systemImage: "square.and.arrow.up")
        }
        Divider()
        Button(role: .destructive) {
            delete(log)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Preview

    private var previewPane: some View {
        Group {
            if let log = selectedLog {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(log.name)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    Divider()
                    ScrollView {
                        Text(preview.isEmpty ? "(empty log)" : preview)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                    Text("Select a log to preview it")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No saved logs yet")
                .font(.headline)
            Text("Right-click a terminal tab and choose Session Log → Log Session Output to start recording.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let log = selectedLog {
                Button {
                    NSWorkspace.shared.open(log.url)
                } label: {
                    Label("Open", systemImage: "doc.text")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([log.url])
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                ShareLink(item: log.url) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .confirmationDialog("Delete this log?",
                                    isPresented: $confirmingDelete,
                                    titleVisibility: .visible) {
                    Button("Delete Log", role: .destructive) { delete(log) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(log.name)
                }
            }
            Spacer()
            Text("\(logs.count) log\(logs.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([TerminalSession.logsDirectory])
            } label: {
                Label("Open Logs Folder", systemImage: "folder")
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Data

    private func reload() {
        let fm = FileManager.default
        let dir = TerminalSession.logsDirectory
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? fm.contentsOfDirectory(at: dir,
                                                includingPropertiesForKeys: keys,
                                                options: [.skipsHiddenFiles])) ?? []
        logs = urls
            .filter { $0.pathExtension.lowercased() == "log" }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return SavedLog(url: url,
                                name: url.lastPathComponent,
                                modified: values?.contentModificationDate ?? .distantPast,
                                size: values?.fileSize ?? 0)
            }
            .sorted { $0.modified > $1.modified }
        // Keep the current selection if it still exists, else select the newest.
        if let selection, logs.contains(where: { $0.url == selection }) {
            // unchanged
        } else {
            selection = logs.first?.url
        }
        loadPreview()
    }

    private func loadPreview() {
        guard let url = selection else { preview = ""; return }
        // Read at most ~256 KB so a huge transcript can't stall the UI.
        guard let handle = try? FileHandle(forReadingFrom: url) else { preview = ""; return }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if data.count == 256 * 1024 {
            text += "\n\n… (truncated — open the file to see the full log)"
        }
        preview = text
    }

    private func delete(_ log: SavedLog) {
        try? FileManager.default.removeItem(at: log.url)
        if selection == log.url { selection = nil }
        reload()
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
