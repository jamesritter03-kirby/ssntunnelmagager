import SwiftUI

/// Where a user-defined command palette command runs.
enum CustomCommandTarget: String, Codable, CaseIterable, Identifiable {
    /// Run in the currently focused terminal tab (does nothing if none is running).
    case activeTerminal
    /// Open a new local shell tab and run the command there.
    case newTerminal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .activeTerminal: return "Active terminal"
        case .newTerminal:    return "New local terminal"
        }
    }
}

/// A user-created command palette action: a named shell command the user can run,
/// edit, and delete straight from the palette.
struct CustomCommand: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String = ""
    var command: String = ""
    var target: CustomCommandTarget = .activeTerminal

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedCommand: String { command.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A display name — the given title, or the command itself if unnamed.
    var displayTitle: String { trimmedTitle.isEmpty ? trimmedCommand : trimmedTitle }

    var isValid: Bool { !trimmedCommand.isEmpty }
}

/// Persists the user's custom command palette commands. A singleton so the palette
/// and its editor share one source of truth.
final class CustomCommandStore: ObservableObject {
    static let shared = CustomCommandStore()

    @Published private(set) var commands: [CustomCommand] = []

    private let storeKey = "customPaletteCommands.v1"

    private init() { load() }

    // MARK: Mutations

    func add(_ command: CustomCommand) {
        commands.append(command)
        save()
    }

    func update(_ command: CustomCommand) {
        guard let index = commands.firstIndex(where: { $0.id == command.id }) else {
            add(command)
            return
        }
        commands[index] = command
        save()
    }

    func delete(id: UUID) {
        commands.removeAll { $0.id == id }
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([CustomCommand].self, from: data) else { return }
        commands = list
    }

    private func save() {
        if let data = try? JSONEncoder().encode(commands) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}
