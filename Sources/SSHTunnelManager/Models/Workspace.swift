import Foundation

/// A "workspace" is one of the big top-level tabs: a named collection of open
/// terminal / browser tabs. The user switches between workspaces, and can save a
/// workspace's tab set to reopen later. Sessions live in a single flat list on
/// `TerminalSessionManager`; a workspace just references them by id, in tab order.
struct Workspace: Identifiable, Equatable {
    let id: UUID
    var name: String
    /// Ordered ids of the sessions (tabs) that belong to this workspace.
    var tabIDs: [UUID]
    /// The selected tab within this workspace.
    var selectedSessionID: UUID?
    /// Whether this workspace lays its tabs out tiled in a grid.
    var isTiled: Bool

    init(id: UUID = UUID(), name: String, tabIDs: [UUID] = [],
         selectedSessionID: UUID? = nil, isTiled: Bool = false) {
        self.id = id
        self.name = name
        self.tabIDs = tabIDs
        self.selectedSessionID = selectedSessionID
        self.isTiled = isTiled
    }
}

// MARK: - Persistence snapshots

/// A minimal, codable description of one open tab — enough to recreate it on the
/// next launch. We deliberately don't try to capture live process state.
struct SessionSnapshot: Codable {
    var kind: TerminalSession.Kind
    var profileID: UUID?
    var webURL: String?
    var title: String?
}

/// A codable description of one workspace and its tabs.
struct WorkspaceSnapshot: Codable {
    var name: String
    var isTiled: Bool
    /// Index (into `tabs`) of the selected tab, if any.
    var selectedIndex: Int?
    var tabs: [SessionSnapshot]
}

/// The whole open-tab state across every workspace, for "resume last session".
struct OpenStateSnapshot: Codable {
    var workspaces: [WorkspaceSnapshot]
    var currentIndex: Int
}

/// A named collection of tabs the user explicitly saved, to reopen on demand.
struct SavedWorkspace: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var tabs: [SessionSnapshot]
}
