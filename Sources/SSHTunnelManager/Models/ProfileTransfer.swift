import Foundation
import AppKit
import UniformTypeIdentifiers

/// Import / export of SSH profiles as a portable JSON file.
///
/// Design notes:
/// - Passwords are **never** exported. They live only in the macOS Keychain.
/// - Imported profiles always receive **fresh ids** so they can't overwrite or
///   collide with existing profiles (or their Keychain entries).
/// - The on-disk file is a small self-describing wrapper so we can evolve the
///   format later, but a bare `[SSHProfile]` array (e.g. a copied
///   `profiles.json`) is also accepted on import.
enum ProfileTransfer {
    /// Self-describing wrapper written to disk.
    struct Document: Codable {
        var format: String
        var version: Int
        var exportedAt: Date
        var profiles: [SSHProfile]

        static let currentFormat = "ssh-tunnel-manager.profiles"
        static let currentVersion = 1
    }

    // MARK: - Encode / decode

    static func encode(_ profiles: [SSHProfile]) throws -> Data {
        let doc = Document(format: Document.currentFormat,
                           version: Document.currentVersion,
                           exportedAt: Date(),
                           profiles: profiles)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(doc)
    }

    /// Decode profiles from our wrapper document or a bare array. Every returned
    /// profile gets a brand-new id.
    static func decode(_ data: Data) throws -> [SSHProfile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let parsed: [SSHProfile]
        if let doc = try? decoder.decode(Document.self, from: data) {
            parsed = doc.profiles
        } else {
            parsed = try decoder.decode([SSHProfile].self, from: data)
        }
        return parsed.map { original in
            var p = original
            p.id = UUID()
            return p
        }
    }

    /// A safe default file name for exporting a single profile.
    static func fileName(for profile: SSHProfile) -> String {
        let base = profile.name.trimmingCharacters(in: .whitespaces)
        let safe = (base.isEmpty ? "Profile" : base)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(safe).json"
    }

    // MARK: - User-facing flows

    /// Present a save panel and write the given profiles to disk.
    @MainActor
    static func exportFlow(_ profiles: [SSHProfile], suggestedName: String) {
        guard !profiles.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Export Profiles"
        panel.message = profiles.count == 1
            ? "Save this profile. Passwords are not included."
            : "Save these \(profiles.count) profiles. Passwords are not included."
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try encode(profiles).write(to: url, options: [.atomic])
        } catch {
            presentError("Couldn’t export profiles.", error)
        }
    }

    /// Present an open panel, decode the chosen file and add the profiles to the
    /// store. Shows a short confirmation (or an error) when finished.
    @MainActor
    static func importFlow(into store: ProfileStore) {
        let panel = NSOpenPanel()
        panel.title = "Import Profiles"
        panel.message = "Choose a profiles file exported from SSH Tunnel Manager."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let imported: [SSHProfile]
        do {
            imported = try decode(try Data(contentsOf: url))
        } catch {
            presentError("Couldn’t import profiles.", error)
            return
        }
        guard !imported.isEmpty else {
            presentError("Nothing to import.",
                         SimpleError("That file didn’t contain any profiles."))
            return
        }

        let count = store.importProfiles(imported)
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Imported 1 profile." : "Imported \(count) profiles."
        alert.informativeText = "Open a profile to re-enter any saved password — passwords aren’t included in exported files."
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - Command snippets

    /// Self-describing wrapper for exported command snippets.
    struct SnippetDocument: Codable {
        var format: String
        var version: Int
        var exportedAt: Date
        var commands: [CommandSnippet]

        static let currentFormat = "ssh-tunnel-manager.commands"
        static let currentVersion = 1
    }

    static func encodeSnippets(_ snippets: [CommandSnippet]) throws -> Data {
        let doc = SnippetDocument(format: SnippetDocument.currentFormat,
                                  version: SnippetDocument.currentVersion,
                                  exportedAt: Date(),
                                  commands: snippets)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(doc)
    }

    /// Decode snippets from our wrapper document or a bare array. Every returned
    /// snippet gets a brand-new id.
    static func decodeSnippets(_ data: Data) throws -> [CommandSnippet] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let parsed: [CommandSnippet]
        if let doc = try? decoder.decode(SnippetDocument.self, from: data) {
            parsed = doc.commands
        } else {
            parsed = try decoder.decode([CommandSnippet].self, from: data)
        }
        return parsed.map { original in
            var c = original
            c.id = UUID()
            return c
        }
    }

    /// A safe default file name for exporting a profile's saved commands.
    static func snippetsFileName(for profile: SSHProfile) -> String {
        let base = profile.name.trimmingCharacters(in: .whitespaces)
        let safe = (base.isEmpty ? "Profile" : base)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(safe) commands.json"
    }

    /// Present a save panel and write the given snippets to disk.
    @MainActor
    static func exportSnippets(_ snippets: [CommandSnippet], suggestedName: String) {
        guard !snippets.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Export Commands"
        panel.message = "Save these \(snippets.count) command\(snippets.count == 1 ? "" : "s")."
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try encodeSnippets(snippets).write(to: url, options: [.atomic])
        } catch {
            presentError("Couldn’t export commands.", error)
        }
    }

    /// Present an open panel and return the decoded snippets (each with a fresh
    /// id). Returns an empty array if cancelled or on error (an alert is shown).
    @MainActor
    static func importSnippets() -> [CommandSnippet] {
        let panel = NSOpenPanel()
        panel.title = "Import Commands"
        panel.message = "Choose a commands file exported from SSH Tunnel Manager."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return [] }
        do {
            let imported = try decodeSnippets(try Data(contentsOf: url))
            if imported.isEmpty {
                presentError("Nothing to import.",
                             SimpleError("That file didn’t contain any commands."))
            }
            return imported
        } catch {
            presentError("Couldn’t import commands.", error)
            return []
        }
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
