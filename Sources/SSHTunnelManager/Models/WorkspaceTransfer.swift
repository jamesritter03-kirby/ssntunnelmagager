import Foundation
import AppKit
import UniformTypeIdentifiers

/// Import / export of saved **workspace launch templates** as a portable JSON
/// file, mirroring `ProfileTransfer`.
///
/// Design notes:
/// - Passwords are **never** exported. Ad-hoc tabs re-prompt on reconnect, so any
///   Keychain credential ids are stripped from imported templates.
/// - Imported workspaces always receive **fresh ids** so they can't collide with
///   existing ones.
/// - The on-disk file is a small self-describing wrapper so the format can evolve,
///   but a bare `[SavedWorkspace]` array is also accepted on import.
enum WorkspaceTransfer {
    /// Self-describing wrapper written to disk.
    struct Document: Codable {
        var format: String
        var version: Int
        var exportedAt: Date
        var workspaces: [SavedWorkspace]

        static let currentFormat = "ssh-tunnel-manager.workspaces"
        static let currentVersion = 1
    }

    /// How to resolve imported workspaces whose names collide with existing ones.
    enum DuplicateResolution { case copies, skip, replace }

    // MARK: - Encode / decode

    static func encode(_ workspaces: [SavedWorkspace]) throws -> Data {
        let doc = Document(format: Document.currentFormat,
                           version: Document.currentVersion,
                           exportedAt: Date(),
                           workspaces: workspaces)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(doc)
    }

    /// Decode workspaces from our wrapper document or a bare array. Every returned
    /// workspace gets a brand-new id and has its tabs' Keychain credential ids
    /// cleared (passwords aren't part of an export).
    static func decode(_ data: Data) throws -> [SavedWorkspace] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let parsed: [SavedWorkspace]
        if let doc = try? decoder.decode(Document.self, from: data) {
            parsed = doc.workspaces
        } else {
            parsed = try decoder.decode([SavedWorkspace].self, from: data)
        }
        return parsed.map { original in
            var w = original
            w.id = UUID()
            w.tabs = w.tabs.map { var t = $0; t.credentialID = nil; return t }
            return w
        }
    }

    /// A safe default file name for exporting a single workspace.
    static func fileName(for workspace: SavedWorkspace) -> String {
        let base = workspace.name.trimmingCharacters(in: .whitespaces)
        let safe = (base.isEmpty ? "Workspace" : base)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(safe).json"
    }

    // MARK: - User-facing flows

    /// Present a save panel and write the given workspaces to disk.
    @MainActor
    static func exportFlow(_ workspaces: [SavedWorkspace], suggestedName: String) {
        guard !workspaces.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Export Workspaces"
        panel.message = workspaces.count == 1
            ? "Save this saved workspace. Passwords are not included."
            : "Save these \(workspaces.count) saved workspaces. Passwords are not included."
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try encode(workspaces).write(to: url, options: [.atomic])
        } catch {
            presentError("Couldn’t export workspaces.", error)
        }
    }

    /// Present an open panel, decode the chosen file and merge the workspaces into
    /// the session manager, prompting how to resolve any duplicate names. Shows a
    /// short confirmation (or an error) when finished.
    @MainActor
    static func importFlow(into sessions: TerminalSessionManager) {
        let panel = NSOpenPanel()
        panel.title = "Import Workspaces"
        panel.message = "Choose a workspaces file exported from Remote Stuff."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let imported: [SavedWorkspace]
        do {
            imported = try decode(try Data(contentsOf: url))
        } catch {
            presentError("Couldn’t import workspaces.", error)
            return
        }
        guard !imported.isEmpty else {
            presentError("Nothing to import.",
                         SimpleError("That file didn’t contain any workspaces."))
            return
        }

        var resolution: DuplicateResolution = .copies
        let dupes = imported.filter { sessions.savedWorkspaceExists(named: $0.name) }
        if !dupes.isEmpty {
            let names = dupes.prefix(8).map(\.name).joined(separator: ", ")
            let more = dupes.count > 8 ? ", …" : ""
            let alert = NSAlert()
            alert.messageText = "Duplicate workspaces found"
            alert.informativeText = "\(dupes.count) of \(imported.count) workspace(s) match the name of one you already have:\n\n\(names)\(more)\n\nHow would you like to handle the duplicates?"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Import as Copies")
            alert.addButton(withTitle: "Skip Duplicates")
            alert.addButton(withTitle: "Replace Existing")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:  resolution = .copies
            case .alertSecondButtonReturn: resolution = .skip
            case .alertThirdButtonReturn:  resolution = .replace
            default: return   // Cancel
            }
        }

        let count = sessions.importSavedWorkspaces(imported, resolution: resolution)
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Imported 1 workspace." : "Imported \(count) workspaces."
        alert.informativeText = "Open one from the Workspace ▸ Open Saved Workspace menu. Passwords aren’t included in exported files — ad-hoc tabs re-prompt on reconnect."
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - Errors

    private struct SimpleError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    @MainActor
    private static func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
