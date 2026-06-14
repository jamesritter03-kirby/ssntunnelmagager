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
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SSHProfile].self, from: data) else {
            return
        }
        profiles = decoded
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
        // Remove any Keychain password tied to this profile.
        KeychainStore.shared.deletePassword(for: profile.id)
    }

    func duplicate(_ profile: SSHProfile) {
        var copy = profile
        copy.id = UUID()
        copy.name += " copy"
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles.insert(copy, at: idx + 1)
        } else {
            profiles.append(copy)
        }
    }
}
