import SwiftUI

/// Drives the searchable command palette. A singleton so a menu command (⌘K)
/// can toggle it and the main window can present it.
final class CommandPaletteModel: ObservableObject {
    static let shared = CommandPaletteModel()
    private init() {}

    @Published var isPresented = false

    func toggle() { isPresented.toggle() }
    func show() { isPresented = true }
}

/// One actionable row in the palette.
struct PaletteItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let systemImage: String
    let run: () -> Void
}
