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
    /// Saved sizing for the tiled grid (row heights and per-row column widths) so
    /// the user's dragged pane sizes are remembered per workspace.
    var tileLayout: TileLayout

    init(id: UUID = UUID(), name: String, tabIDs: [UUID] = [],
         selectedSessionID: UUID? = nil, isTiled: Bool = false,
         tileLayout: TileLayout = TileLayout()) {
        self.id = id
        self.name = name
        self.tabIDs = tabIDs
        self.selectedSessionID = selectedSessionID
        self.isTiled = isTiled
        self.tileLayout = tileLayout
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

    init(id: UUID = UUID(), name: String, tabs: [SessionSnapshot],
         isTiled: Bool = false, tileLayout: TileLayout? = nil) {
        self.id = id
        self.name = name
        self.tabs = tabs
        self.isTiled = isTiled
        self.tileLayout = tileLayout
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
    }
}
