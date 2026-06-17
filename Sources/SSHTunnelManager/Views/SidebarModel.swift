import SwiftUI

/// Holds the split-view column visibility so it can be toggled from both the
/// `ContentView` and the app menu (⌃⌘S). This guarantees a reliable way to bring
/// the sidebar back even if the automatic toolbar toggle button disappears
/// (a known AppKit/SwiftUI quirk when the sidebar is collapsed by dragging).
@MainActor
final class SidebarModel: ObservableObject {
    static let shared = SidebarModel()
    private init() {}

    @Published var columnVisibility: NavigationSplitViewVisibility = .all

    /// Toggle between showing the sidebar and hiding it.
    func toggle() {
        withAnimation(.easeInOut(duration: 0.2)) {
            columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
        }
    }

    /// Force the sidebar visible (used to recover from a stuck-collapsed state).
    func show() {
        withAnimation(.easeInOut(duration: 0.2)) {
            columnVisibility = .all
        }
    }
}
