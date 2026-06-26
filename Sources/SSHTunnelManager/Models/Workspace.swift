import Foundation

/// Which edge a docked column is pinned to.
enum DockSide: String, Codable, Equatable, Hashable {
    case left, right
}

/// One tab inside a side dock column. It stays a live session in the workspace's
/// `tabIDs`; it's just shown stacked in the side drawer instead of the center.
struct DockedPane: Codable, Equatable {
    /// The session shown in this slot of the drawer.
    var sessionID: UUID
    /// This pane's relative vertical weight: stacked panes split the column's
    /// height in proportion to their weights (so 1, 1 = equal halves).
    var heightWeight: Double

    init(sessionID: UUID, heightWeight: Double = 1) {
        self.sessionID = sessionID
        self.heightWeight = heightWeight
    }
}

/// A side drawer pinned to the left or right edge: an ordered vertical stack of
/// one or more docked tabs, a shared width, and a collapsed (slide-out rail)
/// state. All remembered per workspace.
struct DockColumn: Codable, Equatable {
    /// The drawer's width as a fraction of the whole detail area (clamped on use).
    var width: Double
    /// When true the whole column is collapsed to a thin rail with a slide-out button.
    var collapsed: Bool
    /// The stacked tabs, top to bottom.
    var panes: [DockedPane]

    init(width: Double = 0.26, collapsed: Bool = false, panes: [DockedPane] = []) {
        self.width = width
        self.collapsed = collapsed
        self.panes = panes
    }

    /// Session ids of every pane, top to bottom.
    var sessionIDs: [UUID] { panes.map(\.sessionID) }
}

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
    /// Saved sizing for the tiled grid (row heights and per-row column widths) so
    /// the user's dragged pane sizes are remembered per workspace.
    var tileLayout: TileLayout
    /// A drawer pinned to the left edge: a stack of one or more tabs, if any.
    var leftDock: DockColumn?
    /// A drawer pinned to the right edge: a stack of one or more tabs, if any.
    var rightDock: DockColumn?

    init(id: UUID = UUID(), name: String, tabIDs: [UUID] = [],
         selectedSessionID: UUID? = nil, isTiled: Bool = false,
         tileLayout: TileLayout = TileLayout(),
         leftDock: DockColumn? = nil, rightDock: DockColumn? = nil) {
        self.id = id
        self.name = name
        self.tabIDs = tabIDs
        self.selectedSessionID = selectedSessionID
        self.isTiled = isTiled
        self.tileLayout = tileLayout
        self.leftDock = leftDock
        self.rightDock = rightDock
    }
}

/// The remembered sizing of a tiled workspace grid: the relative height of each
/// row and, within each row, the relative width of each column. Everything is
/// stored as fractions (each group sums to 1) so the layout scales with the
/// window. A layout that doesn't match the current grid shape falls back to an
/// even split, so adding or closing a tab never produces a broken arrangement.
struct TileLayout: Codable, Equatable {
    /// Height of each row as a fraction of the grid height (sums to ~1).
    var rowFractions: [Double]
    /// For each row, the width of each column as a fraction (each row sums to ~1).
    var columnFractions: [[Double]]

    init(rowFractions: [Double] = [], columnFractions: [[Double]] = []) {
        self.rowFractions = rowFractions
        self.columnFractions = columnFractions
    }

    /// An even layout for a grid `shape` (the number of columns in each row).
    static func even(shape: [Int]) -> TileLayout {
        guard !shape.isEmpty else { return TileLayout() }
        let rows = Array(repeating: 1.0 / Double(shape.count), count: shape.count)
        let cols = shape.map { count -> [Double] in
            guard count > 0 else { return [] }
            return Array(repeating: 1.0 / Double(count), count: count)
        }
        return TileLayout(rowFractions: rows, columnFractions: cols)
    }

    /// True when this layout's arrays exactly describe `shape`.
    func matches(shape: [Int]) -> Bool {
        guard rowFractions.count == shape.count,
              columnFractions.count == shape.count else { return false }
        for (count, fractions) in zip(shape, columnFractions)
            where fractions.count != count { return false }
        return true
    }

    /// This layout if it fits `shape`, otherwise an even layout for that shape.
    func conformed(to shape: [Int]) -> TileLayout {
        matches(shape: shape) ? self : .even(shape: shape)
    }

    /// Move the boundary between elements `index` and `index + 1` of a fraction
    /// group by `delta` (in fraction units), keeping the group's total constant
    /// and neither neighbour smaller than `minFraction`. Returns the new group.
    static func resized(_ fractions: [Double], boundary index: Int,
                        by delta: Double, minFraction: Double) -> [Double] {
        guard fractions.indices.contains(index),
              fractions.indices.contains(index + 1) else { return fractions }
        var result = fractions
        // The left pane can shrink to `minFraction` (delta ≥ minFraction - left)
        // and the right pane likewise (delta ≤ right - minFraction).
        let lowerBound = minFraction - result[index]
        let upperBound = result[index + 1] - minFraction
        guard upperBound >= lowerBound else { return fractions }   // no room either way
        let clamped = min(max(delta, lowerBound), upperBound)
        result[index] += clamped
        result[index + 1] -= clamped
        return result
    }
}

/// Geometry helpers for arranging N tiles into a near-square grid. Kept here (a
/// plain, dependency-free file) so the layout math can be unit-tested in
/// isolation.
enum TileGrid {
    /// Number of columns in each row for `count` tiles: 1→[1], 2→[2], 3→[2,1],
    /// 4→[2,2], 5→[3,2], 6→[3,3], 7→[3,3,1]… (a near-square arrangement).
    static func shape(forCount count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let columns = max(1, Int(Double(count).squareRoot().rounded(.up)))
        var shape: [Int] = []
        var remaining = count
        while remaining > 0 {
            let inThisRow = min(columns, remaining)
            shape.append(inThisRow)
            remaining -= inThisRow
        }
        return shape
    }

    /// Slice `items` into rows following `shape`.
    static func rows<T>(_ items: [T], shape: [Int]) -> [[T]] {
        var rows: [[T]] = []
        var index = 0
        for count in shape {
            let end = min(index + count, items.count)
            guard index < end else { break }
            rows.append(Array(items[index..<end]))
            index = end
        }
        return rows
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
    /// For `.mqtt` / `.redis` tabs: the forwarded local port the client used, so
    /// the matching forward can be found and relaunched. Optional so snapshots
    /// written by older versions still decode.
    var servicePort: Int? = nil
}

// Hand-written decoder so snapshots saved before `servicePort` existed still load
// (the synthesized one would throw on the missing key and drop the resume state).
extension SessionSnapshot {
    enum CodingKeys: String, CodingKey {
        case kind, profileID, webURL, title, servicePort
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(TerminalSession.Kind.self, forKey: .kind) ?? .localShell
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
        webURL = try c.decodeIfPresent(String.self, forKey: .webURL)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        servicePort = try c.decodeIfPresent(Int.self, forKey: .servicePort)
    }
}

/// A codable description of one workspace and its tabs.
struct WorkspaceSnapshot: Codable {
    var name: String
    var isTiled: Bool
    /// Saved tiled-grid sizing, if the workspace had a custom layout (optional so
    /// snapshots written by older versions still decode).
    var tileLayout: TileLayout? = nil
    /// Index (into `tabs`) of the selected tab, if any.
    var selectedIndex: Int?
    var tabs: [SessionSnapshot]
    /// Side drawers, by tab index (optional so older snapshots still decode).
    var docks: [DockSnapshot]? = nil
}

/// A codable description of a docked side drawer; its tabs are referenced by
/// their index into the workspace's tab list so they re-pair after a relaunch.
struct DockSnapshot: Codable {
    var side: DockSide
    var width: Double
    var collapsed: Bool
    var panes: [DockPaneSnapshot]
    /// Legacy single-pane field (pre-1.9.10). Kept only so old saved state decodes.
    var tabIndex: Int? = nil

    enum CodingKeys: String, CodingKey { case side, width, collapsed, panes, tabIndex }

    init(side: DockSide, width: Double, collapsed: Bool, panes: [DockPaneSnapshot]) {
        self.side = side
        self.width = width
        self.collapsed = collapsed
        self.panes = panes
    }

    // Decode the current multi-pane shape, falling back to the old single
    // `tabIndex` so docks saved by 1.9.9 still restore (as a one-tab column).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        side = try c.decode(DockSide.self, forKey: .side)
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0.26
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        if let panes = try c.decodeIfPresent([DockPaneSnapshot].self, forKey: .panes) {
            self.panes = panes
        } else if let idx = try c.decodeIfPresent(Int.self, forKey: .tabIndex) {
            self.panes = [DockPaneSnapshot(tabIndex: idx, heightWeight: 1)]
        } else {
            self.panes = []
        }
    }
}

/// One tab within a docked drawer snapshot: its index into the workspace's tab
/// list, plus its relative height within the column.
struct DockPaneSnapshot: Codable {
    var tabIndex: Int
    var heightWeight: Double

    init(tabIndex: Int, heightWeight: Double = 1) {
        self.tabIndex = tabIndex
        self.heightWeight = heightWeight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tabIndex = try c.decode(Int.self, forKey: .tabIndex)
        heightWeight = try c.decodeIfPresent(Double.self, forKey: .heightWeight) ?? 1
    }
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
    /// Whether the workspace was tiled when saved.
    var isTiled: Bool = false
    /// Saved tiled-grid sizing for the workspace, if any.
    var tileLayout: TileLayout? = nil
    /// Side drawers, by tab index, if any.
    var docks: [DockSnapshot]? = nil

    init(id: UUID = UUID(), name: String, tabs: [SessionSnapshot],
         isTiled: Bool = false, tileLayout: TileLayout? = nil,
         docks: [DockSnapshot]? = nil) {
        self.id = id
        self.name = name
        self.tabs = tabs
        self.isTiled = isTiled
        self.tileLayout = tileLayout
        self.docks = docks
    }

    // Custom decoding so library entries saved before `isTiled` / `tileLayout`
    // existed still load. Synthesized `Decodable` would throw `keyNotFound` on the
    // missing `isTiled` key *despite* its default value (a default only feeds the
    // memberwise initializer, not decoding) — which would silently wipe the whole
    // saved-workspace library on upgrade. Decoding each newer field "if present"
    // keeps old data readable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        tabs = try c.decode([SessionSnapshot].self, forKey: .tabs)
        isTiled = try c.decodeIfPresent(Bool.self, forKey: .isTiled) ?? false
        tileLayout = try c.decodeIfPresent(TileLayout.self, forKey: .tileLayout)
        docks = try c.decodeIfPresent([DockSnapshot].self, forKey: .docks)
    }
}
