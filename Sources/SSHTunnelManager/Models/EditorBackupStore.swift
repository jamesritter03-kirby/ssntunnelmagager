import Foundation

/// A crash‑safe snapshot of one text‑editor tab's **unsaved** state, mirroring
/// Notepad++'s backup behaviour. Persisted as JSON so that quitting (or crashing)
/// with unsaved edits — including brand‑new untitled documents — restores the
/// exact buffer on the next launch instead of losing it.
struct EditorBackupRecord: Codable {
    /// The document's file on disk, if it has been saved anywhere. `nil` for a
    /// never‑saved untitled document.
    var filePath: String?
    /// The full editor buffer (`\n`‑delimited, as the editor works internally).
    var content: String
    /// Whether the buffer differs from what's on disk (true for untitled docs).
    var isDirty: Bool
    /// `CodeLanguage.rawValue` for the chosen syntax highlighting.
    var language: String
    /// `LineEnding.rawValue`.
    var lineEnding: String
    /// `String.Encoding.rawValue`.
    var encoding: UInt
}

/// Stores per‑editor backups on disk, keyed by the editor's stable id, so the
/// text a user typed but never saved survives relaunches and crashes.
///
/// Backups live in `Application Support/SSHTunnelManager/EditorBackups/<id>.json`.
/// A backup is written (debounced) while there is unsaved work and removed once
/// the document is saved/clean or its tab is pruned from the resume state.
final class EditorBackupStore {
    static let shared = EditorBackupStore()

    private let dir: URL
    private let fm = FileManager.default
    /// Serialises disk access so debounced writes from the editor and pruning
    /// from the session manager never race.
    private let queue = DispatchQueue(label: "com.local.sshtunnelmanager.editorbackups")

    private init() {
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        dir = base.appendingPathComponent("SSHTunnelManager/EditorBackups", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func url(for id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString).json")
    }

    /// Store (or replace) the backup for an editor. Writes atomically off the
    /// main thread.
    func write(id: UUID, record: EditorBackupRecord) {
        let url = url(for: id)
        queue.async {
            guard let data = try? JSONEncoder().encode(record) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Load a previously saved backup, or `nil` if none exists / it can't be read.
    func load(id: UUID) -> EditorBackupRecord? {
        queue.sync {
            guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
            return try? JSONDecoder().decode(EditorBackupRecord.self, from: data)
        }
    }

    /// Remove an editor's backup (called when it's saved/clean or discarded).
    func remove(id: UUID) {
        let url = url(for: id)
        queue.async { try? self.fm.removeItem(at: url) }
    }

    /// Delete every backup whose id isn't in `keepIDs` — orphans left behind by
    /// tabs that were closed since the last save of the resume state.
    func prune(keeping keepIDs: Set<UUID>) {
        queue.async {
            guard let files = try? self.fm.contentsOfDirectory(at: self.dir,
                                                               includingPropertiesForKeys: nil) else { return }
            for file in files where file.pathExtension == "json" {
                let name = file.deletingPathExtension().lastPathComponent
                if let id = UUID(uuidString: name), keepIDs.contains(id) { continue }
                try? self.fm.removeItem(at: file)
            }
        }
    }
}
