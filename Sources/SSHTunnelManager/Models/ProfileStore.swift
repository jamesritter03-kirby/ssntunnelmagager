import Foundation
import Combine

/// Loads and persists SSH profiles as JSON in Application Support.
final class ProfileStore: ObservableObject {
    @Published var profiles: [SSHProfile] = []

    private let fileURL: URL
    private var isLoading = false
    private var cancellable: AnyCancellable?

    static let shared = ProfileStore()

    private init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("SSHTunnelManager", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("profiles.json")

        load()

        // Auto-save whenever the profiles change (but not during the initial load).
        cancellable = $profiles
            .dropFirst()
            .sink { [weak self] profiles in
                guard let self, !self.isLoading else { return }
                self.save(profiles)
            }
    }

    /// Absolute path of the profiles file (shown in the UI / README).
    var storagePath: String { fileURL.path }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([SSHProfile].self, from: data) {
            profiles = decoded
        }

        // On the very first launch (no saved profiles yet, and we've never seeded
        // before) populate a few example profiles that showcase the options. The
        // flag means deleting the examples won't bring them back next launch.
        let seededKey = "didSeedExampleProfiles"
        if profiles.isEmpty && !UserDefaults.standard.bool(forKey: seededKey) {
            profiles = SSHProfile.examples
            UserDefaults.standard.set(true, forKey: seededKey)
            save(profiles)
        }
    }

    private func save(_ profiles: [SSHProfile]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(profiles) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    // MARK: - Mutations

    func add(_ profile: SSHProfile) {
        profiles.append(profile)
    }

    func update(_ profile: SSHProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
    }

    func delete(_ profile: SSHProfile) {
        profiles.removeAll { $0.id == profile.id }
        // Remove any Keychain password tied to this profile (its SSH password and
        // each forward's service password are keyed by their own ids).
        KeychainStore.shared.deletePassword(for: profile.id)
        for forward in profile.forwards {
            KeychainStore.shared.deletePassword(for: forward.id)
        }
    }

    @discardableResult
    func duplicate(_ profile: SSHProfile) -> SSHProfile {
        var copy = profile
        copy.id = UUID()
        // Give the copy's forwards fresh ids too, so it doesn't share (or, on
        // delete, clobber) the original's Keychain service passwords. Like the
        // SSH password, saved service passwords aren't carried into the copy.
        copy.forwards = copy.forwards.map { var f = $0; f.id = UUID(); return f }
        copy.name += " copy"
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles.insert(copy, at: idx + 1)
        } else {
            profiles.append(copy)
        }
        return copy
    }

    /// Append imported profiles, giving each a unique display name so they don't
    /// visually collide with existing ones. Returns the number added.
    @discardableResult
    func importProfiles(_ incoming: [SSHProfile]) -> Int {
        var added = 0
        for var profile in incoming {
            profile.name = uniqueName(for: profile.name)
            profiles.append(profile)
            added += 1
        }
        return added
    }

    /// A display name that doesn't already exist, suffixing " (2)", " (3)"… as needed.
    private func uniqueName(for proposed: String) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? "Imported Profile" : trimmed
        let existing = Set(profiles.map(\.name))
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) (\(n))") { n += 1 }
        return "\(base) (\(n))"
    }
}
