import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The detail pane: a tab bar plus the active terminal, or a welcome screen.
struct TerminalAreaView: View {
    @EnvironmentObject var sessions: TerminalSessionManager

    var body: some View {
        VStack(spacing: 0) {
            // The workspace switcher used to live in the window title bar as a
            // `.principal` toolbar item, but those intermittently vanish when the
            // window loses and regains key focus (e.g. switching to a detached
            // terminal window and back). An ordinary slim row is reliable.
            WorkspaceBar()
            Divider()
            if sessions.attachedSessions.isEmpty {
                if sessions.currentWorkspaceSessions.isEmpty {
                    WelcomeView()
                } else {
                    AllDetachedView()
                }
            } else {
                // The center tab bar + terminals, flanked by any side drawers.
                DetailAreaView()
            }
        }
    }
}

/// The area below the workspace bar: the center tab bar + terminals, with any
/// docked tabs shown as collapsible, resizable drawers on the left and/or right.
/// Each drawer can stack several docked tabs vertically.
private struct DetailAreaView: View {
    @EnvironmentObject var sessions: TerminalSessionManager

    /// While dragging an edge divider: the guide line's position (x for left/right,
    /// y for top/bottom, in detail-area coordinates) and which side it belongs to.
    /// The drawer keeps its committed size during the drag — only this lightweight
    /// line moves — so the live terminals don't re-lay-out on every pixel (which
    /// made dragging jumpy). The new size is committed once, on release.
    @State private var crossGuide: CGFloat?
    @State private var crossGuideSide: DockSide?
    @State private var crossDragBase: Double?
    @State private var pendingCross: Double?

    private let dividerThickness: CGFloat = 8
    private let minDockWidth: CGFloat = 200
    private let minDockHeight: CGFloat = 120
    private let railWidth: CGFloat = 34

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    if let top = sessions.topDock {
                        DockColumnView(column: top, side: .top)
                            .frame(height: crossSize(top, .top, total: geo.size))
                        if !top.collapsed {
                            edgeDivider(.top, column: top, total: geo.size)
                        }
                    }

                    centerRow(geo.size)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if let bottom = sessions.bottomDock {
                        if !bottom.collapsed {
                            edgeDivider(.bottom, column: bottom, total: geo.size)
                        }
                        DockColumnView(column: bottom, side: .bottom)
                            .frame(height: crossSize(bottom, .bottom, total: geo.size))
                    }
                }
                if let g = crossGuide, let s = crossGuideSide {
                    crossGuideLine(g, side: s, in: geo.size)
                }
            }
        }
    }

    /// The center row, with optional left/right drawers beside the tab area. These
    /// span the height between the top/bottom drawers — like an editor's sidebars
    /// sitting between a top toolbar and a bottom panel.
    @ViewBuilder private func centerRow(_ total: CGSize) -> some View {
        HStack(spacing: 0) {
            if let left = sessions.leftDock {
                DockColumnView(column: left, side: .left)
                    .frame(width: crossSize(left, .left, total: total))
                if !left.collapsed {
                    edgeDivider(.left, column: left, total: total)
                }
            }

            center
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let right = sessions.rightDock {
                if !right.collapsed {
                    edgeDivider(.right, column: right, total: total)
                }
                DockColumnView(column: right, side: .right)
                    .frame(width: crossSize(right, .right, total: total))
            }
        }
    }

    /// The center column: the tab bar + tiled / single terminal area, or a hint
    /// when every tab has been docked to a side.
    @ViewBuilder private var center: some View {
        VStack(spacing: 0) {
            if sessions.centerSessions.isEmpty {
                DockedOnlyCenter()
            } else {
                TabBar()
                Divider()
                if sessions.isTiled && sessions.centerSessions.count > 1 {
                    TiledTerminalsView(items: sessions.centerSessions)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // SwiftUI's split views cache their NSSplitView divider /
                        // row state. Without a stable identity that changes when the
                        // tile set does, switching from a 2-tile workspace to a
                        // 4-tile one would reuse the old 2-pane layout. Re-key on the
                        // workspace + its tab ids so the grid is rebuilt correctly.
                        .id(tiledLayoutID)
                } else {
                    // If the "selected" tab is docked (or selection is nil), still
                    // show a center tab so this area is never blank.
                    let centerIDs = sessions.centerSessions
                    let shownID = centerIDs.contains(where: { $0.id == sessions.selectedSessionID })
                        ? sessions.selectedSessionID
                        : centerIDs.first?.id
                    ZStack {
                        ForEach(sessions.centerSessions) { session in
                            TerminalContainer(session: session,
                                              isVisible: session.id == shownID)
                                .opacity(session.id == shownID ? 1 : 0)
                                .allowsHitTesting(session.id == shownID)
                                // Keep the visible tab topmost. Every tab stays
                                // mounted (to keep processes alive) and stacks
                                // here; without this the visible one may sit
                                // *under* a hidden sibling, which — while it lets
                                // mouse clicks pass through — still blocks file
                                // drops from reaching the terminal below it.
                                .zIndex(session.id == shownID ? 1 : 0)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// Resolved cross-axis size in points for a drawer (a thin rail when collapsed).
    private func crossSize(_ column: DockColumn, _ side: DockSide, total: CGSize) -> CGFloat {
        guard !column.collapsed else { return railWidth }
        return resolvedCross(fraction: column.width, side: side, total: total)
    }

    /// Clamp a cross-axis fraction to sensible points (min readable size, ≤45%).
    /// The cross axis is width for left/right drawers, height for top/bottom.
    private func resolvedCross(fraction: Double, side: DockSide, total: CGSize) -> CGFloat {
        let main = side.isHorizontal ? total.height : total.width
        let minSize = side.isHorizontal ? minDockHeight : minDockWidth
        let cap = max(railWidth, main * 0.45)
        return min(max(CGFloat(fraction) * main, minSize), cap)
    }

    /// A draggable divider between a drawer and the center area. It only moves a
    /// guide line during the drag and commits the new size on release, so the
    /// terminals don't reflow on every pixel. Works on either axis.
    private func edgeDivider(_ side: DockSide, column: DockColumn, total: CGSize) -> some View {
        let horizontal = side.isHorizontal
        return TileDivider(orientation: horizontal ? .horizontal : .vertical,
                           isActive: crossGuideSide == side)
            .frame(width: horizontal ? nil : dividerThickness,
                   height: horizontal ? dividerThickness : nil)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if crossDragBase == nil { crossDragBase = column.width }
                        let base = crossDragBase ?? column.width
                        let main = horizontal ? total.height : total.width
                        // Dragging away from the edge enlarges the drawer.
                        let deltaPts: CGFloat
                        switch side {
                        case .left:   deltaPts = value.translation.width
                        case .right:  deltaPts = -value.translation.width
                        case .top:    deltaPts = value.translation.height
                        case .bottom: deltaPts = -value.translation.height
                        }
                        let rawFraction = base + Double(deltaPts / max(1, main))
                        let pts = resolvedCross(fraction: rawFraction, side: side, total: total)
                        crossGuideSide = side
                        crossGuide = guidePosition(side: side, pts: pts, total: total)
                        pendingCross = Double(pts / main)
                    }
                    .onEnded { _ in
                        if let f = pendingCross { sessions.setColumnWidth(side, fraction: f) }
                        crossGuide = nil
                        crossGuideSide = nil
                        crossDragBase = nil
                        pendingCross = nil
                    }
            )
    }

    /// Absolute position (x for vertical edges, y for horizontal edges) of the
    /// drag guide for a drawer of `pts` cross-size.
    private func guidePosition(side: DockSide, pts: CGFloat, total: CGSize) -> CGFloat {
        switch side {
        case .left:   return pts
        case .right:  return total.width - pts
        case .top:    return pts
        case .bottom: return total.height - pts
        }
    }

    /// The lightweight guide line shown while dragging an edge divider.
    @ViewBuilder
    private func crossGuideLine(_ pos: CGFloat, side: DockSide, in total: CGSize) -> some View {
        if side.isHorizontal {
            Capsule().fill(Color.accentColor)
                .frame(width: total.width, height: 2)
                .position(x: total.width / 2, y: pos)
                .allowsHitTesting(false)
        } else {
            Capsule().fill(Color.accentColor)
                .frame(width: 2, height: total.height)
                .position(x: pos, y: total.height / 2)
                .allowsHitTesting(false)
        }
    }

    private var tiledLayoutID: String {
        let ids = sessions.centerSessions.map(\.id.uuidString).joined(separator: ",")
        return "\(sessions.currentWorkspaceID.uuidString):\(ids)"
    }
}

/// A drawer: one or more docked tabs stacked along the drawer's main axis, each
/// with a slim header, separated by draggable dividers. Left/right drawers stack
/// vertically; top/bottom drawers stack horizontally. Collapsed, the whole drawer
/// becomes a thin rail with a slide-out button. Its cross-axis size is dragged via
/// the divider supplied by `DetailAreaView`; everything is remembered per workspace.
private struct DockColumnView: View {
    @EnvironmentObject var sessions: TerminalSessionManager
    let column: DockColumn
    let side: DockSide

    private let dividerThickness: CGFloat = 8
    private let minPaneHeight: CGFloat = 90
    private let minPaneWidth: CGFloat = 140

    // Pane-resize guide: like the edge divider and the tile grid, the panes keep
    // their committed sizes during a drag (only this line moves), so terminals
    // don't reflow per pixel. The new split is committed on release.
    @State private var paneGuide: CGFloat?
    @State private var paneDragBoundary: Int?
    @State private var paneDragBase: [Double]?
    @State private var pendingWeights: [Double]?

    private var panes: [DockedPane] { column.panes }
    /// Top/bottom drawers stack their panes horizontally.
    private var isHorizontal: Bool { side.isHorizontal }

    var body: some View {
        Group {
            if column.collapsed {
                rail
            } else {
                expanded
            }
        }
        .background(.bar)
        // A drawer has a fixed cross-size, but .frame doesn't clip: wide/tall
        // content (e.g. a Finder tab with long names) would otherwise bleed over
        // the center area or off-screen, hiding the header's collapse button.
        // Clipping keeps everything — most importantly each pane's toolbar —
        // inside the drawer's visible bounds.
        .clipped()
        .overlay(edgeBorder)
    }

    /// Collapsed: a thin rail of status dots + icons; click to slide the whole
    /// drawer back out. Runs vertically for left/right, horizontally for top/bottom.
    private var rail: some View {
        Button {
            sessions.toggleColumnCollapsed(side)
        } label: {
            let layout = isHorizontal
                ? AnyLayout(HStackLayout(spacing: 14))
                : AnyLayout(VStackLayout(spacing: 14))
            layout {
                Image(systemName: railChevron)
                    .font(.system(size: 11, weight: .bold))
                ForEach(panes, id: \.sessionID) { pane in
                    if let session = sessions.session(id: pane.sessionID) {
                        VStack(spacing: 5) {
                            Circle().fill(statusColor(session)).frame(width: 6, height: 6)
                            Image(systemName: session.symbolName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(isHorizontal ? .horizontal : .vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Slide out the docked tabs")
    }

    /// Chevron on the collapsed rail, pointing the way the drawer slides out.
    private var railChevron: String {
        switch side {
        case .left:   return "chevron.right"
        case .right:  return "chevron.left"
        case .top:    return "chevron.down"
        case .bottom: return "chevron.up"
        }
    }

    /// Expanded: the panes stacked along the main axis, with a draggable divider
    /// between each pair to size them.
    private var expanded: some View {
        GeometryReader { geo in
            let committed = panes.map(\.heightWeight)
            let sum = max(0.0001, committed.reduce(0, +))
            let mainLength = isHorizontal ? geo.size.width : geo.size.height
            let available = max(1, mainLength
                                - dividerThickness * CGFloat(max(0, panes.count - 1)))
            let layout = isHorizontal
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))
            ZStack(alignment: .topLeading) {
                layout {
                    ForEach(Array(panes.enumerated()), id: \.element.sessionID) { index, pane in
                        if let session = sessions.session(id: pane.sessionID) {
                            let length = available * CGFloat(committed[index] / sum)
                            DockPaneView(session: session, side: side)
                                .frame(width: isHorizontal ? length : nil,
                                       height: isHorizontal ? nil : length)
                        }
                        if index < panes.count - 1 {
                            TileDivider(orientation: isHorizontal ? .vertical : .horizontal,
                                        isActive: paneDragBoundary == index)
                                .frame(width: isHorizontal ? dividerThickness : nil,
                                       height: isHorizontal ? nil : dividerThickness)
                                .gesture(paneDrag(boundary: index,
                                                  available: available, sum: sum))
                        }
                    }
                }
                if let g = paneGuide {
                    if isHorizontal {
                        Capsule().fill(Color.accentColor)
                            .frame(width: 2, height: geo.size.height)
                            .position(x: g, y: geo.size.height / 2)
                            .allowsHitTesting(false)
                    } else {
                        Capsule().fill(Color.accentColor)
                            .frame(width: geo.size.width, height: 2)
                            .position(x: geo.size.width / 2, y: g)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    /// Drag gesture for the divider between stacked panes `i` and `i+1`.
    private func paneDrag(boundary i: Int, available: CGFloat, sum: Double) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let base = paneDragBase ?? panes.map(\.heightWeight)
                if paneDragBase == nil { paneDragBase = base }
                paneDragBoundary = i
                guard base.indices.contains(i + 1) else { return }
                let minMain = isHorizontal ? minPaneWidth : minPaneHeight
                let minWeight = Double(minMain / available) * sum
                let translation = isHorizontal ? value.translation.width
                                               : value.translation.height
                let delta = Double(translation / available) * sum
                var w = base
                let lo = minWeight - w[i]
                let hi = w[i + 1] - minWeight
                guard hi >= lo else { return }
                let clamped = min(max(delta, lo), hi)
                w[i] += clamped
                w[i + 1] -= clamped
                pendingWeights = w
                let leadingFraction = w.prefix(i + 1).reduce(0, +) / sum
                paneGuide = available * CGFloat(leadingFraction)
                    + dividerThickness * CGFloat(i) + dividerThickness / 2
            }
            .onEnded { _ in
                if let w = pendingWeights { sessions.setColumnPaneWeights(side, w) }
                paneGuide = nil
                paneDragBoundary = nil
                paneDragBase = nil
                pendingWeights = nil
            }
    }

    /// A subtle separating line on the inner edge (toward the center area).
    @ViewBuilder private var edgeBorder: some View {
        let line = Rectangle().fill(Color.secondary.opacity(0.18))
        switch side {
        case .left:
            line.frame(width: 1).frame(maxWidth: .infinity, alignment: .trailing)
                .allowsHitTesting(false)
        case .right:
            line.frame(width: 1).frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
        case .top:
            line.frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
        case .bottom:
            line.frame(height: 1).frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        }
    }

    private func statusColor(_ session: TerminalSession) -> Color {
        if session.isRunning { return .green }
        if let code = session.exitCode, code != 0 { return .red }
        return .secondary
    }
}

/// One tab inside a side drawer: a slim header (status, title, return-to-tabs and
/// collapse buttons) above its live content. Several of these stack inside a
/// `DockColumnView`.
private struct DockPaneView: View {
    @EnvironmentObject var sessions: TerminalSessionManager
    @ObservedObject var session: TerminalSession
    let side: DockSide

    var body: some View {
        VStack(spacing: 0) {
            header
                .zIndex(1)          // keep the collapse/return controls on top
            Divider()
            // The content keeps its natural width (long Finder names / a wide
            // toolbar may overflow), but it's clipped to the pane so it can't
            // spill sideways over the header's collapse button or the center area.
            TerminalContainer(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            // Collapse + return live on the leading edge: the drawer clips its
            // content to a fixed size, and the leading edge is always a visible
            // one, so these controls never get clipped by wide/tall content.
            Button {
                sessions.toggleColumnCollapsed(side)
            } label: {
                Image(systemName: collapseChevron)
            }
            .buttonStyle(.borderless)
            .help("Collapse this drawer to a rail")
            Button {
                sessions.undock(session)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("Return this tab to the tab bar")
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Image(systemName: session.symbolName)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(session.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu { menu }
    }

    @ViewBuilder private var menu: some View {
        TerminalTabContextMenu(
            session: session,
            onDetach: {
                sessions.undock(session)
                DetachedTerminalController.shared.detach(session)
            },
            onClose: { sessions.close(session) }
        )
    }

    /// Header collapse chevron, pointing toward the edge the drawer collapses to.
    private var collapseChevron: String {
        switch side {
        case .left:   return "chevron.left"
        case .right:  return "chevron.right"
        case .top:    return "chevron.up"
        case .bottom: return "chevron.down"
        }
    }

    private var statusColor: Color {
        if session.isRunning { return .green }
        if let code = session.exitCode, code != 0 { return .red }
        return .secondary
    }
}

/// Shown in the center when every tab in the workspace has been docked to a side.
/// Keeps the "tabs are docked" hint, then offers the same full set of starting
/// points as the welcome screen (not just "New Local Terminal") so any kind of
/// new tab can be opened right here.
private struct DockedOnlyCenter: View {
    @EnvironmentObject var sessions: TerminalSessionManager

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    Image(systemName: "sidebar.squares.leading")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                    Text("Tabs are docked to the side")
                        .font(.title3.weight(.semibold))
                    Text("Use a drawer's return button to bring a tab back here, or open a new one below.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                WelcomeLaunchOptions(showsResume: false)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }
}

/// The top-level bar of "workspace" tabs — each a saveable collection of
/// terminal / browser tabs. Lets the user switch, add, rename, close and save
/// workspaces, and reopen previously saved ones.
private struct WorkspaceBar: View {
    @EnvironmentObject var sessions: TerminalSessionManager

    @State private var renamingID: UUID?
    @State private var nameField = ""
    @State private var isSaving = false
    @State private var saveField = ""
    @State private var isSavingAsProfile = false
    @State private var profileNameField = ""
    @State private var pendingProfileWorkspaceID: UUID?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(sessions.workspaces) { ws in
                WorkspacePill(
                    workspace: ws,
                    isCurrent: ws.id == sessions.currentWorkspaceID,
                    tabCount: sessions.tabCount(in: ws.id),
                    canClose: sessions.workspaces.count > 1,
                    isSaved: sessions.isWorkspaceSaved(ws.id),
                    onSelect: { sessions.switchWorkspace(to: ws.id) },
                    onClose: { sessions.closeWorkspace(ws.id) },
                    onRename: { beginRename(ws) },
                    onQuickSave: { sessions.saveWorkspaceInPlace(ws.id) },
                    onSave: { beginSave(ws) },
                    onSaveAsProfile: { beginSaveAsProfile(ws) },
                    onSetColor: { sessions.setWorkspaceColor($0, forWorkspace: ws.id) }
                )
                .onDrag {
                    NSItemProvider(object: ws.id.uuidString as NSString)
                }
                .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                        guard let idString = object as? String,
                              let uuid = UUID(uuidString: idString),
                              uuid != ws.id else { return }
                        DispatchQueue.main.async {
                            sessions.moveWorkspace(fromID: uuid, toID: ws.id)
                        }
                    }
                    return true
                }
            }
            Button { sessions.addWorkspace() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("New workspace (⌘⇧N)")

            savedMenu
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
        .alert("Rename Workspace", isPresented: renamingBinding) {
            TextField("Name", text: $nameField)
            Button("Cancel", role: .cancel) { renamingID = nil }
            Button("Rename") {
                if let id = renamingID { sessions.renameWorkspace(id, to: nameField) }
                renamingID = nil
            }
        }
        .alert("Save Workspace", isPresented: $isSaving) {
            TextField("Name", text: $saveField)
            Button("Cancel", role: .cancel) { isSaving = false }
            Button("Save") {
                sessions.saveCurrentWorkspace(name: saveField)
                isSaving = false
            }
        } message: {
            Text("Save this workspace's tabs so you can reopen them later from the workspaces menu.")
        }
        .alert("Save Workspace as Profile", isPresented: $isSavingAsProfile) {
            TextField("Profile name", text: $profileNameField)
            Button("Cancel", role: .cancel) { pendingProfileWorkspaceID = nil }
            Button("Save") { finishSaveAsProfile() }
        } message: {
            Text("Create a profile that reopens this workspace's tabs. It appears in the sidebar and welcome screen; each tab reconnects through its own profile. When you set the profile's host in the editor, you can point every tab at that address.")
        }
    }

    private var savedMenu: some View {
        Menu {
            Button {
                beginSave(sessions.currentWorkspace)
            } label: {
                Label("Save Current Workspace…", systemImage: "square.and.arrow.down")
            }
            if !sessions.savedWorkspaces.isEmpty {
                Section("Open Saved Workspace") {
                    ForEach(sessions.savedWorkspaces) { saved in
                        Button {
                            sessions.openSavedWorkspace(saved)
                        } label: {
                            Label("\(saved.name) (\(saved.tabs.count))",
                                  systemImage: "square.stack.3d.up.fill")
                        }
                    }
                }
                Menu {
                    ForEach(sessions.savedWorkspaces) { saved in
                        Button(role: .destructive) {
                            sessions.deleteSavedWorkspace(saved.id)
                        } label: {
                            Label(saved.name, systemImage: "trash")
                        }
                    }
                } label: {
                    Label("Delete Saved Workspace", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "square.stack.3d.up.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Save or open workspaces")
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })
    }

    private func beginRename(_ ws: Workspace) {
        nameField = ws.name
        renamingID = ws.id
    }

    private func beginSave(_ ws: Workspace?) {
        saveField = ws?.name ?? ""
        isSaving = true
    }

    private func beginSaveAsProfile(_ ws: Workspace) {
        profileNameField = ws.name
        pendingProfileWorkspaceID = ws.id
        isSavingAsProfile = true
    }

    /// Perform the save-as-profile using the pending workspace + typed name, then
    /// open the new profile's editor (where the host can be set and its tabs
    /// re-pointed at that address).
    private func finishSaveAsProfile() {
        guard let id = pendingProfileWorkspaceID else { return }
        pendingProfileWorkspaceID = nil
        guard let profile = sessions.saveWorkspaceAsProfile(id, name: profileNameField) else { return }
        // Deferred so the alert fully dismisses before the editor sheet appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            ProfileEditCoordinator.shared.profileToEdit = profile
        }
    }
}

// MARK: - Tab / workspace tinting

extension TabColor {
    /// The SwiftUI color this palette entry paints. Kept here (a view file) so the
    /// `TabColor` model itself stays free of any SwiftUI dependency.
    var color: Color {
        switch self {
        case .red:    return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green:  return .green
        case .teal:   return .teal
        case .blue:   return .blue
        case .purple: return .purple
        case .pink:   return .pink
        }
    }

    /// The AppKit color used when drawing a menu swatch bitmap.
    var nsColor: NSColor {
        switch self {
        case .red:    return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green:  return .systemGreen
        case .teal:   return .systemTeal
        case .blue:   return .systemBlue
        case .purple: return .systemPurple
        case .pink:   return .systemPink
        }
    }

    /// A filled-circle swatch drawn as a real (non-template) bitmap so it keeps
    /// its color inside an `NSMenu` — where SwiftUI's `.foregroundStyle` on an SF
    /// Symbol is dropped and the glyph renders as a monochrome template. When
    /// `selected` is true a white check is drawn over the circle.
    func menuSwatch(selected: Bool) -> Image {
        let side: CGFloat = 13
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            self.nsColor.setFill()
            circle.fill()
            if selected {
                let check = NSBezierPath()
                check.lineWidth = 1.7
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                check.move(to: NSPoint(x: rect.width * 0.27, y: rect.height * 0.50))
                check.line(to: NSPoint(x: rect.width * 0.43, y: rect.height * 0.33))
                check.line(to: NSPoint(x: rect.width * 0.74, y: rect.height * 0.68))
                NSColor.white.setStroke()
                check.stroke()
            }
            return true
        }
        image.isTemplate = false
        return Image(nsImage: image)
    }
}

/// A reusable "Tab Color" right-click submenu: a swatch for each palette entry
/// plus a "Default" item that clears the tint. Used by both the tab chips and
/// the workspace pills — `current` shows the active choice with a checkmark and
/// `onPick` applies (or clears, with `nil`) it.
private struct TabColorMenu: View {
    let current: TabColor?
    let onPick: (TabColor?) -> Void

    var body: some View {
        Menu {
            Button { onPick(nil) } label: {
                Label {
                    Text("Default")
                } icon: {
                    Image(systemName: current == nil ? "checkmark.circle.fill" : "circle.dashed")
                }
            }
            Divider()
            ForEach(TabColor.allCases) { c in
                Button { onPick(c) } label: {
                    Label {
                        Text(c.label)
                    } icon: {
                        c.menuSwatch(selected: current == c)
                    }
                }
            }
        } label: {
            Label("Tab Color", systemImage: "paintpalette")
        }
    }
}

/// One workspace "pill" in the workspace bar.
private struct WorkspacePill: View {
    let workspace: Workspace
    let isCurrent: Bool
    let tabCount: Int
    let canClose: Bool
    var isSaved: Bool = false
    var onSelect: () -> Void
    var onClose: () -> Void
    var onRename: () -> Void
    var onQuickSave: () -> Void = {}
    var onSave: () -> Void
    var onSaveAsProfile: () -> Void = {}
    var onSetColor: (TabColor?) -> Void = { _ in }

    /// The pill's tint: the user's chosen color, or the default accent.
    private var tint: Color { workspace.tabColor?.color ?? .accentColor }
    private var pillBackground: Color {
        if isCurrent { return tint.opacity(0.22) }
        return workspace.tabColor != nil ? tint.opacity(0.16) : Color.secondary.opacity(0.10)
    }
    private var pillBorder: Color {
        if isCurrent { return tint.opacity(0.7) }
        return workspace.tabColor != nil ? tint.opacity(0.4) : .clear
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .font(.caption2)
                .foregroundStyle(isCurrent || workspace.tabColor != nil ? tint : .secondary)
            Text(workspace.name)
                .font(.callout.weight(isCurrent ? .semibold : .regular))
                .lineLimit(1)
            Text("\(tabCount)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.18)))
            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help("Close workspace")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(pillBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(pillBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button { onRename() } label: { Label("Rename…", systemImage: "pencil") }
            Button { onQuickSave() } label: {
                Label(isSaved ? "Update Saved Workspace" : "Save Workspace",
                      systemImage: isSaved ? "arrow.triangle.2.circlepath" : "square.and.arrow.down")
            }
            Button { onSave() } label: { Label("Save as Workspace…", systemImage: "square.and.arrow.down.on.square") }
            Button { onSaveAsProfile() } label: { Label("Save as Profile…", systemImage: "rectangle.stack.badge.plus") }
            Divider()
            TabColorMenu(current: workspace.tabColor) { onSetColor($0) }
            if canClose {
                Divider()
                Button(role: .destructive) { onClose() } label: {
                    Label("Close Workspace", systemImage: "xmark")
                }
            }
        }
    }
}

private struct TabBar: View {
    @EnvironmentObject var sessions: TerminalSessionManager
    @EnvironmentObject var store: ProfileStore

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sessions.centerSessions) { session in
                        TabChip(
                            session: session,
                            isSelected: session.id == sessions.selectedSessionID,
                            onSelect: { sessions.select(session) },
                            onClose: { sessions.close(session) },
                            onDetach: { DetachedTerminalController.shared.detach(session) }
                        )
                        .onDrag {
                            NSItemProvider(object: session.id.uuidString as NSString)
                        }
                        .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                            guard let provider = providers.first else { return false }
                            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                                guard let idString = object as? String,
                                      let uuid = UUID(uuidString: idString),
                                      let fromIndex = sessions.centerSessions.firstIndex(where: { $0.id == uuid }),
                                      let toIndex = sessions.centerSessions.firstIndex(where: { $0.id == session.id }),
                                      fromIndex != toIndex else { return }
                                DispatchQueue.main.async {
                                    sessions.moveCenterTab(from: fromIndex, to: toIndex)
                                }
                            }
                            return true
                        }
                    }
                    Menu {
                        Button {
                            sessions.openLocalShell()
                        } label: {
                            Label("New Local Terminal", systemImage: "terminal")
                        }
                        Button {
                            sessions.openBlankWeb()
                        } label: {
                            Label("New Browser Tab", systemImage: "globe")
                        }
                        Button {
                            sessions.openFinder()
                        } label: {
                            Label("New Finder Tab", systemImage: "folder")
                        }
                        Button {
                            sessions.openTextEditor()
                        } label: {
                            Label("New Text Editor", systemImage: "doc.text")
                        }
                        Button {
                            sessions.openSpreadsheet()
                        } label: {
                            Label("New Spreadsheet", systemImage: "tablecells")
                        }
                        Divider()
                        Button {
                            RemoteConnectionModel.shared.present(.ssh)
                        } label: {
                            Label("New Remote Terminal…", systemImage: "network")
                        }
                        Button {
                            RemoteConnectionModel.shared.present(.sftp)
                        } label: {
                            Label("New SFTP Connection…", systemImage: "arrow.up.arrow.down")
                        }
                        Button {
                            ServiceConnectionModel.shared.present(.mqtt)
                        } label: {
                            Label("New MQTT Connection…", systemImage: ForwardCategory.mqtt.symbol)
                        }
                        Button {
                            ServiceConnectionModel.shared.present(.redis)
                        } label: {
                            Label("New Redis Connection…", systemImage: ForwardCategory.redis.symbol)
                        }
                        Button {
                            VNCConnectionModel.shared.present()
                        } label: {
                            Label("New VNC Connection…", systemImage: "display")
                        }
                        if !store.profiles.isEmpty {
                            Divider()
                            Menu {
                                ForEach(store.profiles) { profile in
                                    Button {
                                        sessions.connect(profile: profile)
                                    } label: {
                                        Label(profile.name, systemImage: profile.displayIcon)
                                    }
                                }
                            } label: {
                                Label("Connect to Profile", systemImage: "network")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("New tab — terminal, browser, or a profile connection")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            if let session = sessions.selectedSession {
                Divider().frame(height: 22)
                if session.kind == .ssh || session.kind == .localShell {
                    SnippetsMenuButton(session: session)
                }
                if session.supportsCommandHistory {
                    HistoryMenuButton(session: session)
                }
                LinksMenuButton(session: session)
                if session.kind != .web && session.kind != .finder {
                    DisconnectButton(session: session)
                }
            }

            Divider().frame(height: 22)
            Button {
                sessions.isTiled.toggle()
            } label: {
                Image(systemName: sessions.isTiled ? "square" : "rectangle.split.2x2")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .disabled(sessions.centerSessions.count < 2)
            .help(sessions.isTiled ? "Show one tab at a time" : "Tile all tabs side by side")
        }
        .background(.bar)
    }
}

/// A drop-down of the active profile's saved commands; click one to insert it.
/// Always shown for a profile-backed shell tab (so it stays next to History) —
/// when the profile has no snippets yet it still offers **Edit Snippets…**, so
/// they're easy to find and add.
private struct SnippetsMenuButton: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var sessions: TerminalSessionManager

    /// The profile whose snippets this tab shows: its own assigned profile if it
    /// has one, otherwise the profile that launched its workspace (so a workspace
    /// launcher's tabs surface that launcher profile's snippets).
    private var profile: SSHProfile? {
        if let pid = session.profileID,
           let p = store.profiles.first(where: { $0.id == pid }) {
            return p
        }
        return sessions.owningProfile(forSession: session.id)
    }

    var body: some View {
        if let profile {
            Menu {
                if profile.snippets.isEmpty {
                    Text("No snippets yet")
                } else {
                    ForEach(profile.snippets) { snippet in
                        Menu(snippet.label.isEmpty ? snippet.command : snippet.label) {
                            Button("Run") { session.run(snippet.command) }
                            Button("Insert at Prompt") { session.paste(snippet.command) }
                        }
                        .disabled(!session.isRunning || snippet.command.isEmpty)
                    }
                }
                Divider()
                Button {
                    ProfileEditCoordinator.shared.profileToEdit = profile
                } label: {
                    Label("Edit Snippets…", systemImage: "pencil")
                }
            } label: {
                Image(systemName: "text.badge.plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.leading, 8)
            .help("Insert a saved command, or edit this profile's snippets")
        }
    }
}

/// A drop-down of the active profile's saved links; click one to open it in an
/// in-app browser tab.
private struct LinksMenuButton: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var sessions: TerminalSessionManager

    private var profile: SSHProfile? {
        if let pid = session.profileID,
           let p = store.profiles.first(where: { $0.id == pid }) {
            return p
        }
        return sessions.owningProfile(forSession: session.id)
    }

    var body: some View {
        if let profile, !profile.links.isEmpty {
            Menu {
                ForEach(profile.links) { link in
                    Button {
                        sessions.openLink(link, profile: profile)
                    } label: {
                        Label(link.displayLabel, systemImage: "globe")
                    }
                    .disabled(link.normalizedURL == nil)
                }
            } label: {
                Image(systemName: "globe")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.leading, 8)
            .help("Open a saved link in a browser tab")
        }
    }
}

/// A drop-down of the selected tab's previous commands; click one to run it again.
private struct HistoryMenuButton: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        Menu {
            if session.commandHistory.isEmpty {
                Text("No commands yet")
            } else {
                ForEach(Array(session.commandHistory.reversed().prefix(40).enumerated()), id: \.offset) { entry in
                    Button(displayTitle(entry.element)) {
                        session.rerun(entry.element)
                    }
                    .disabled(!session.isRunning)
                }
            }
            Divider()
            // Import is always available (even with no history yet) so a tab can
            // be seeded from an exported file or a shell's own history.
            Button("Import History…") {
                importHistory()
            }
            if !session.commandHistory.isEmpty {
                Button("Save History…") {
                    saveHistory()
                }
                Button("Clear History", role: .destructive) {
                    session.clearHistory()
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Command history — click a command to run it again")
    }

    private func displayTitle(_ command: String) -> String {
        command.count > 60 ? String(command.prefix(59)) + "…" : command
    }
    /// Write the tab's command history to a user-chosen text file.
    private func saveHistory() {
        let panel = NSSavePanel()
        panel.title = "Save Command History"
        panel.nameFieldStringValue = session.suggestedHistoryFileName
        panel.allowedContentTypes = [.plainText]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try session.historyExportText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Load commands from a user-chosen text file into this tab's history. Accepts
    /// files exported by Save History… as well as plain shell history files
    /// (`.bash_history`, `.zsh_history`); hidden files are shown so those dotfiles
    /// can be picked.
    private func importHistory() {
        let panel = NSOpenPanel()
        panel.title = "Import Command History"
        panel.message = "Choose a text file with one command per line (an exported history file, or a shell's .bash_history / .zsh_history)."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // `.data` lets extensionless dotfiles be selected; we decode as text and
        // tolerate non-UTF-8 bytes, so a non-text file just yields no commands.
        panel.allowedContentTypes = [.plainText, .text, .data]
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Lossy UTF-8 decode never throws, so zsh's meta-encoded bytes don't
            // abort the import; only a genuine read error (permissions) does.
            let data = try Data(contentsOf: url)
            let text = String(decoding: data, as: UTF8.self)
            let added = session.importHistory(fromText: text)
            reportImport(added: added)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Tell the user how many commands were imported (or that none were found).
    private func reportImport(added: Int) {
        let alert = NSAlert()
        if added > 0 {
            alert.alertStyle = .informational
            alert.messageText = "Imported \(added) command\(added == 1 ? "" : "s")"
            alert.informativeText = "They're now in this tab's history — click the clock to run any of them again."
        } else {
            alert.alertStyle = .warning
            alert.messageText = "No commands imported"
            alert.informativeText = "That file didn't contain any commands (after skipping blank and comment lines)."
        }
        alert.runModal()
    }
}

/// Disconnects the selected tab's process (closing its SSH tunnel) while keeping
/// the tab open so it can be reconnected. Disabled once the session has ended.
private struct DisconnectButton: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        Button {
            session.disconnect()
        } label: {
            Image(systemName: "bolt.horizontal.circle")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .disabled(!session.isRunning)
        .help(session.isRemote
              ? "Disconnect this tunnel (you can reconnect)"
              : "Stop this terminal (you can restart it)")
    }
}

/// The shared right-click menu for a terminal tab. Used both by the tab chip in
/// the tab bar and by the header bar of a tile in the tiled layout, so a tile's
/// title bar offers the very same actions (Snippets, Links, Disconnect/Stop,
/// SFTP, VNC, Detach, Close) as right-clicking its tab.
private struct TerminalTabContextMenu: View {
    @EnvironmentObject var sessions: TerminalSessionManager
    @EnvironmentObject var store: ProfileStore
    @ObservedObject var session: TerminalSession
    var onDetach: () -> Void
    var onClose: () -> Void

    /// The profile backing this tab, if any (local shells have none).
    private var profile: SSHProfile? {
        guard let pid = session.profileID else { return nil }
        return store.profiles.first(where: { $0.id == pid })
    }

    /// The profile whose connection this tab represents: its own, or the profile
    /// that launched its workspace — so an ad-hoc tab rebuilt inside a launcher
    /// workspace still resolves the connection behind it. Backs “Edit Connection…”
    /// and “Open SFTP” for terminal tabs.
    private var effectiveProfile: SSHProfile? {
        if let profile { return profile }
        return sessions.owningProfile(forSession: session.id)
    }

    /// Whether “Open SFTP” applies to this tab: an ssh terminal can always SFTP to
    /// the same host; any other tab needs a profile-backed, non-local connection.
    /// (An SFTP tab itself is excluded.)
    private var canLaunchSFTP: Bool {
        guard session.kind != .sftp else { return false }
        if session.kind == .ssh { return true }
        return (effectiveProfile.map { !$0.isLocal }) ?? false
    }

    /// Open an SFTP file-transfer tab to the same server as this connection.
    private func launchSFTP() {
        if let profile = effectiveProfile, !profile.isLocal {
            sessions.connectSFTP(profile: profile)
        } else if session.kind == .ssh {
            // A pure ad-hoc ssh tab: SFTP to the same host / port / user.
            sessions.openAdHocSFTP(host: session.serviceHost,
                                   port: session.servicePort ?? 22,
                                   username: session.serviceUsername,
                                   password: session.presetPassword ?? "")
        }
    }

    /// "Open Redis (:6379)" style label for a categorized forward.
    private func serviceMenuLabel(_ forward: PortForward) -> String {
        let suffix = forward.localEndpoint.map { " (:\($0.port))" } ?? ""
        if !forward.trimmedName.isEmpty {
            return "\(forward.trimmedName)\(suffix)"
        }
        return "Open \(forward.category.title)\(suffix)"
    }

    /// The per-tab "Theme" submenu, mirroring the profile editor's theme picker
    /// (grouped into Dark / Light, with a checkmark on the active theme).
    private var themeMenu: some View {
        Menu {
            Section("Dark") {
                ForEach(TerminalTheme.dark) { themeButton($0) }
            }
            Section("Light") {
                ForEach(TerminalTheme.light) { themeButton($0) }
            }
        } label: {
            Label("Theme", systemImage: "paintpalette")
        }
    }

    @ViewBuilder
    private func themeButton(_ theme: TerminalTheme) -> some View {
        Button {
            applyTheme(theme)
        } label: {
            if theme.id == session.theme.id {
                Label(theme.name, systemImage: "checkmark")
            } else {
                Text(theme.name)
            }
        }
    }

    /// Apply a chosen theme. For a profile-backed tab this saves the theme to the
    /// profile and recolors every open tab from it — exactly like changing the
    /// theme in the profile editor and saving. A plain local shell (no profile)
    /// just recolors its own live terminal.
    private func applyTheme(_ theme: TerminalTheme) {
        if let profile {
            var updated = profile
            updated.theme = theme.id
            store.update(updated)
            sessions.applyTheme(theme, toProfileID: profile.id)
        } else {
            session.applyTheme(theme)
        }
    }

    /// Write the terminal's full output (scrollback + screen) to a chosen file.
    private func saveTerminalOutput() {
        let panel = NSSavePanel()
        panel.title = "Save Terminal Output"
        panel.nameFieldStringValue = session.suggestedTerminalOutputFileName
        panel.allowedContentTypes = [.plainText]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try session.terminalBufferText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    var body: some View {
        // Editor tabs get file-specific actions (Save, Reveal, Copy Path, …)
        // at the top; the generic Dock / Detach / Close items follow below.
        if session.kind == .editor, let editorModel = session.textEditorModel {
            EditorTabContextMenu(session: session, model: editorModel)
            Divider()
        }
        if session.kind == .spreadsheet, let sheetModel = session.spreadsheetModel {
            SpreadsheetTabContextMenu(session: session, model: sheetModel)
            Divider()
        }
        // Snippets submenu (terminal tabs only)
        if let profile, !profile.snippets.isEmpty,
           session.kind == .ssh || session.kind == .localShell {
            Menu {
                ForEach(profile.snippets) { snippet in
                    Menu(snippet.label.isEmpty ? snippet.command : snippet.label) {
                        Button("Run") { session.run(snippet.command) }
                        Button("Insert at Prompt") { session.paste(snippet.command) }
                    }
                    .disabled(!session.isRunning || snippet.command.isEmpty)
                }
            } label: {
                Label("Snippets", systemImage: "text.badge.plus")
            }
        }
        // Links submenu (any tab whose profile has links)
        if let profile, !profile.links.isEmpty {
            Menu {
                ForEach(profile.links) { link in
                    Button {
                        sessions.openLink(link, profile: profile)
                    } label: {
                        Label(link.displayLabel, systemImage: "globe")
                    }
                    .disabled(link.normalizedURL == nil)
                }
            } label: {
                Label("Links", systemImage: "globe")
            }
        }
        // Services submenu (categorized forwards → Web / MQTT / Redis tabs)
        if let profile, !profile.categorizedForwards.isEmpty {
            Menu {
                ForEach(profile.categorizedForwards) { forward in
                    Button {
                        sessions.openService(forward.category, forward: forward, profile: profile)
                    } label: {
                        Label(serviceMenuLabel(forward), systemImage: forward.category.symbol)
                    }
                }
            } label: {
                Label("Services", systemImage: "square.grid.2x2")
            }
        }
        if let profile,
           (!profile.snippets.isEmpty && (session.kind == .ssh || session.kind == .localShell))
           || !profile.links.isEmpty || !profile.categorizedForwards.isEmpty {
            Divider()
        }
        if session.kind != .web && session.kind != .finder && session.kind != .editor
            && session.kind != .spreadsheet {
            Button {
                session.disconnect()
            } label: {
                Label(session.isRemote ? "Disconnect" : "Stop",
                      systemImage: "bolt.horizontal.circle")
            }
            .disabled(!session.isRunning)
        }
        // Type the profile's saved password at the current prompt (Touch ID as the
        // profile configures) without revealing it — a reliable fallback for a
        // password prompt the auto-fill doesn't recognise.
        if (session.kind == .ssh || session.kind == .localShell),
           session.hasSavedPasswordToSend {
            Button {
                session.sendSavedPassword()
            } label: {
                Label("Enter Saved Password", systemImage: "key.fill")
            }
            .disabled(!session.isRunning)
        }
        // Terminal buffer actions (interactive shells only): copy or save the
        // scrollback, and clear the screen.
        if session.kind == .ssh || session.kind == .localShell {
            Divider()
            Button {
                session.copyTerminalBuffer()
            } label: {
                Label("Copy Terminal Output", systemImage: "doc.on.doc")
            }
            Button {
                saveTerminalOutput()
            } label: {
                Label("Save Terminal Output…", systemImage: "square.and.arrow.down")
            }
            Button {
                session.clearTerminal()
            } label: {
                Label("Clear Terminal", systemImage: "clear")
            }
        }
        // Edit the connection behind a terminal tab — its profile's host, port,
        // credentials and forwards — in the full profile editor.
        if (session.kind == .ssh || session.kind == .localShell), let profile = effectiveProfile {
            Button {
                ProfileEditCoordinator.shared.profileToEdit = profile
            } label: {
                Label("Edit Connection…", systemImage: "pencil")
            }
        }
        if session.canEditConnection {
            Button {
                EditConnectionModel.shared.present(for: session)
            } label: {
                Label("Edit Connection…", systemImage: "pencil")
            }
        }
        // Mount the SFTP connection as a Finder drive (via sshfs/FUSE). Falls back
        // to the fuse-t setup page when no mount helper is installed.
        if session.kind == .sftp, let mounter = session.sftpMounter, mounter.canMount {
            if mounter.isMounted {
                Button {
                    mounter.unmount()
                } label: {
                    Label("Unmount Drive", systemImage: "eject")
                }
            } else {
                Button {
                    if SFTPMounter.helperInstalled {
                        mounter.mount()
                    } else if let url = URL(string: "https://www.fuse-t.org/") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Mount with FUSE…", systemImage: "externaldrive.badge.plus")
                }
                .disabled(mounter.isBusy)
            }
        }
        if session.kind == .vnc, let viewer = session.embeddedVNCViewer {
            VNCTabOptionsMenu(viewer: viewer)
        }
        if canLaunchSFTP {
            Button {
                launchSFTP()
            } label: {
                Label("Open SFTP", systemImage: "arrow.up.arrow.down")
            }
        }
        if let profile, !profile.isLocal, session.kind != .vnc {
            Button {
                sessions.connectVNC(profile: profile)
            } label: {
                Label("Open VNC", systemImage: "display")
            }
        }
        if let profile, !profile.isLocal {
            Button {
                sessions.setUpKeyLogin(profile: profile)
            } label: {
                Label("Set Up Passwordless Login…", systemImage: "key")
            }
        }
        if session.kind == .localShell {
            Button {
                sessions.setUpKeyLoginPrompt()
            } label: {
                Label("Set Up Passwordless Login…", systemImage: "key")
            }
        }
        if session.kind == .ssh || session.kind == .localShell {
            themeMenu
        }
        TabColorMenu(current: session.tabColor) { color in
            sessions.setTabColor(color, forSession: session.id)
        }
        Divider()
        Menu {
            if sessions.dockSide(of: session.id) != .left {
                Button {
                    sessions.dock(session, to: .left)
                } label: {
                    Label("Dock Left", systemImage: "rectangle.lefthalf.filled")
                }
            }
            if sessions.dockSide(of: session.id) != .right {
                Button {
                    sessions.dock(session, to: .right)
                } label: {
                    Label("Dock Right", systemImage: "rectangle.righthalf.filled")
                }
            }
            if sessions.dockSide(of: session.id) != .top {
                Button {
                    sessions.dock(session, to: .top)
                } label: {
                    Label("Dock Top", systemImage: "rectangle.tophalf.filled")
                }
            }
            if sessions.dockSide(of: session.id) != .bottom {
                Button {
                    sessions.dock(session, to: .bottom)
                } label: {
                    Label("Dock Bottom", systemImage: "rectangle.bottomhalf.filled")
                }
            }
            if sessions.isDocked(session.id) {
                Divider()
                Button {
                    sessions.toggleDockCollapsed(session.id)
                } label: {
                    Label("Collapse / Expand", systemImage: "arrow.left.and.right")
                }
                Button {
                    sessions.undock(session)
                } label: {
                    Label("Return to Tabs", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
        } label: {
            Label("Dock", systemImage: "sidebar.right")
        }
        if session.canDuplicate {
            Button {
                sessions.duplicate(session)
            } label: {
                Label("Duplicate Tab", systemImage: "plus.square.on.square")
            }
        }
        Button {
            onDetach()
        } label: {
            Label("Detach into New Window", systemImage: "macwindow.badge.plus")
        }
        Divider()
        Button(role: .destructive) {
            onClose()
        } label: {
            Label("Close Tab", systemImage: "xmark")
        }
    }
}

/// The file-oriented right-click actions for a text-editor tab, prepended to the
/// shared `TerminalTabContextMenu` for `.editor` sessions. Mirrors the editor
/// toolbar's file commands (Save / Save As / Revert) and adds the usual Finder
/// niceties (Reveal, Open externally, Copy Path / Name) plus a quick Compare
/// against any other open document. Shown both on the tab chip and on a tile's
/// header, so a tiled editor offers the same actions as its tab.
private struct EditorTabContextMenu: View {
    @EnvironmentObject var sessions: TerminalSessionManager
    @ObservedObject var session: TerminalSession
    @ObservedObject var model: TextEditorModel

    /// Other open editor tabs, eligible as the right-hand side of a compare.
    private var otherEditors: [TerminalSession] {
        sessions.sessions.filter {
            $0.kind == .editor && $0.id != session.id && $0.textEditorModel != nil
        }
    }

    private func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    var body: some View {
        Button {
            model.save()
        } label: {
            Label("Save", systemImage: "square.and.arrow.down")
        }
        .disabled(model.fileURL != nil && !model.isDirty)

        Button {
            model.saveAs()
        } label: {
            Label("Save As…", systemImage: "square.and.arrow.down.on.square")
        }

        if model.fileURL != nil {
            Button {
                model.revertToSaved()
            } label: {
                Label("Revert to Saved", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.isDirty)
        }

        if let url = model.fileURL {
            Divider()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open in Default App", systemImage: "arrow.up.forward.app")
            }
            Divider()
            Button {
                copyToPasteboard(url.path)
            } label: {
                Label("Copy Full Path", systemImage: "doc.on.doc")
            }
            Button {
                copyToPasteboard(url.lastPathComponent)
            } label: {
                Label("Copy File Name", systemImage: "textformat")
            }
        }

        // Compare against another open document (Scintilla engine only, since it
        // drives the side-by-side diff view).
        if model.useScintillaEngine {
            Divider()
            Menu {
                if otherEditors.isEmpty {
                    Text("No other open files")
                } else {
                    ForEach(otherEditors, id: \.id) { other in
                        Button(other.textEditorModel?.displayName ?? "Untitled") {
                            guard let target = other.textEditorModel else { return }
                            model.beginCompare(withText: target.pendingContent,
                                               name: target.displayName)
                        }
                    }
                }
            } label: {
                Label("Compare With", systemImage: "arrow.left.arrow.right")
            }
            .disabled(otherEditors.isEmpty)
        }

        Divider()
        Button {
            sessions.openTextEditor()
        } label: {
            Label("New Text Editor", systemImage: "doc.badge.plus")
        }
        Button {
            sessions.openSpreadsheet()
        } label: {
            Label("New Spreadsheet", systemImage: "tablecells")
        }
    }
}

/// The spreadsheet-specific items shown at the top of a `.spreadsheet` tab's
/// right-click menu: save actions, Open in Excel / the default app, reveal in
/// Finder, copy path, and a New Spreadsheet shortcut.
private struct SpreadsheetTabContextMenu: View {
    @EnvironmentObject var sessions: TerminalSessionManager
    @ObservedObject var session: TerminalSession
    @ObservedObject var model: SpreadsheetModel

    private func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    var body: some View {
        Button {
            model.save()
        } label: {
            Label("Save", systemImage: "square.and.arrow.down")
        }
        .disabled(model.fileURL != nil && !model.isDirty)

        Button {
            model.saveAs()
        } label: {
            Label("Save As…", systemImage: "square.and.arrow.down.on.square")
        }

        if model.fileURL != nil {
            Button {
                model.revertToSaved()
            } label: {
                Label("Revert to Saved", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.isDirty)
        }

        Divider()
        Button {
            model.openInExcel()
        } label: {
            Label("Open in Excel", systemImage: "tablecells")
        }

        if let url = model.fileURL {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open in Default App", systemImage: "arrow.up.forward.app")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            Divider()
            Button {
                copyToPasteboard(url.path)
            } label: {
                Label("Copy Full Path", systemImage: "doc.on.doc")
            }
            Button {
                copyToPasteboard(url.lastPathComponent)
            } label: {
                Label("Copy File Name", systemImage: "textformat")
            }
        }

        Divider()
        Button {
            sessions.openSpreadsheet()
        } label: {
            Label("New Spreadsheet", systemImage: "doc.badge.plus")
        }
    }
}

/// The VNC-specific options shown in a `.vnc` tab's right-click menu: display
/// scaling, colour depth, view-only / clipboard toggles, and quick actions like
/// Send Ctrl+Alt+Del, Reconnect and Open in Screen Sharing. Observing the viewer
/// keeps the checkmarks in sync with the live connection's settings.
private struct VNCTabOptionsMenu: View {
    @ObservedObject var viewer: EmbeddedVNCViewer

    var body: some View {
        Menu {
            // Display scaling (mutually exclusive).
            Menu {
                checkButton("Scale to Fit Window", on: viewer.isScalingEnabled) {
                    viewer.setScaling(true)
                }
                checkButton("Actual Size", on: !viewer.isScalingEnabled) {
                    viewer.setScaling(false)
                }
            } label: {
                Label("Scaling", systemImage: "arrow.up.left.and.arrow.down.right")
            }

            // Colour depth (mutually exclusive).
            Menu {
                ForEach(EmbeddedVNCViewer.ColorDepthOption.allCases) { depth in
                    checkButton(depth.title, on: viewer.colorDepth == depth) {
                        viewer.setColorDepth(depth)
                    }
                }
            } label: {
                Label("Color Depth", systemImage: "paintpalette")
            }

            Divider()

            Toggle(isOn: Binding(get: { viewer.isViewOnly },
                                 set: { viewer.setViewOnly($0) })) {
                Label("View Only", systemImage: "eye")
            }
            Toggle(isOn: Binding(get: { viewer.isClipboardSharingEnabled },
                                 set: { viewer.setClipboardSharing($0) })) {
                Label("Share Clipboard", systemImage: "doc.on.clipboard")
            }

            Divider()

            Button { viewer.sendCtrlAltDel() } label: {
                Label("Send Ctrl+Alt+Del", systemImage: "command")
            }
            .disabled(viewer.status != .connected)
            Button { viewer.reconnect() } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            Button { viewer.openExternal() } label: {
                Label("Open in Screen Sharing", systemImage: "macwindow")
            }
        } label: {
            Label("VNC", systemImage: "display")
        }
    }

    /// A menu button that shows a leading checkmark when `on` is true.
    @ViewBuilder
    private func checkButton(_ title: String, on: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if on {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

private struct TabChip: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    var onDetach: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Image(systemName: session.symbolName)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(session.title)
                .lineLimit(1)
                .font(.callout)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Close tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(chipBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(chipBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            TerminalTabContextMenu(session: session, onDetach: onDetach, onClose: onClose)
        }
    }

    private var statusColor: Color {
        if session.isRunning { return .green }
        if let code = session.exitCode, code != 0 { return .red }
        return .secondary
    }

    /// The chip's tint: the user's chosen color, or the default accent.
    private var tint: Color { session.tabColor?.color ?? .accentColor }
    private var chipBackground: Color {
        if isSelected { return tint.opacity(0.20) }
        return session.tabColor != nil ? tint.opacity(0.16) : Color.secondary.opacity(0.12)
    }
    private var chipBorder: Color {
        if isSelected { return tint.opacity(0.6) }
        return session.tabColor != nil ? tint.opacity(0.4) : .clear
    }
}

/// Lays out every attached terminal in a resizable grid (all kept live), with a
/// header per tile and a highlight on the selected one. The user can drag the
/// dividers to resize panes; the sizes are stored as fractions on the workspace
/// (`TileLayout`) so they're remembered when switching workspaces and across
/// launches. The layout scales with the window because everything is fractional.
private struct TiledTerminalsView: View {
    @EnvironmentObject var sessions: TerminalSessionManager
    let items: [TerminalSession]

    /// While a divider drag is in progress, the previewed layout. It drives only
    /// the guide line — not the tiles — so the live terminals don't re-lay-out on
    /// every pixel. `nil` when not dragging.
    @State private var dragLayout: TileLayout?
    /// The layout captured when the current drag began; the drag's translation is
    /// applied relative to this so the guide tracks the pointer exactly.
    @State private var dragAnchor: TileLayout?
    /// Which divider is being dragged (drives the guide line and keeps the source
    /// divider highlighted). `nil` when not dragging.
    @State private var activeDivider: ActiveDivider?

    /// Identifies the divider under the drag: a boundary between two rows, or a
    /// boundary between two columns within a given row.
    private enum ActiveDivider: Equatable {
        case row(Int)
        case column(row: Int, boundary: Int)
    }

    private let dividerThickness: CGFloat = 8
    private let minTileWidth: CGFloat = 160
    private let minTileHeight: CGFloat = 110

    private var shape: [Int] { TileGrid.shape(forCount: items.count) }

    var body: some View {
        let shape = self.shape
        let rows = TileGrid.rows(items, shape: shape)
        // The committed layout always drives the tile frames, so the live
        // terminals only re-lay-out once — when the drag ends — instead of on
        // every pixel of the drag (which made the panes and divider flicker). The
        // in-progress drag is shown with a lightweight guide line instead.
        let committed = sessions.currentTileLayout.conformed(to: shape)
        GeometryReader { geo in
            let availableHeight = max(1, geo.size.height
                                      - dividerThickness * CGFloat(max(0, rows.count - 1)))
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        tileRow(rowIndex: rowIndex, row: row, layout: committed,
                                totalWidth: geo.size.width)
                            .frame(height: CGFloat(committed.rowFractions[rowIndex]) * availableHeight)

                        if rowIndex < rows.count - 1 {
                            TileDivider(orientation: .horizontal,
                                        isActive: activeDivider == .row(rowIndex))
                                .frame(height: dividerThickness)
                                .gesture(rowDrag(boundary: rowIndex, shape: shape,
                                                 availableHeight: availableHeight))
                        }
                    }
                }
                dragGuide(committed: committed, geo: geo, availableHeight: availableHeight)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(6)
    }

    /// One row of the grid: its tiles separated by draggable vertical dividers.
    private func tileRow(rowIndex: Int, row: [TerminalSession],
                         layout: TileLayout, totalWidth: CGFloat) -> some View {
        let columns = row.count
        let availableWidth = max(1, totalWidth
                                 - dividerThickness * CGFloat(max(0, columns - 1)))
        return HStack(spacing: 0) {
            ForEach(Array(row.enumerated()), id: \.element.id) { columnIndex, session in
                TerminalTile(session: session,
                             isSelected: session.id == sessions.selectedSessionID)
                    .frame(width: CGFloat(layout.columnFractions[rowIndex][columnIndex]) * availableWidth)

                if columnIndex < columns - 1 {
                    TileDivider(orientation: .vertical,
                                isActive: activeDivider == .column(row: rowIndex, boundary: columnIndex))
                        .frame(width: dividerThickness)
                        .gesture(columnDrag(row: rowIndex, boundary: columnIndex,
                                            shape: shape, availableWidth: availableWidth))
                }
            }
        }
    }

    /// The highlighted guide line shown at the divider's would-be position during
    /// a drag. Its position comes from the previewed layout; the tiles themselves
    /// don't move until the drag ends, so nothing re-lays-out per pixel.
    @ViewBuilder
    private func dragGuide(committed: TileLayout, geo: GeometryProxy,
                           availableHeight: CGFloat) -> some View {
        if let activeDivider, let preview = dragLayout {
            switch activeDivider {
            case .row(let index):
                let y = horizontalDividerCenter(preview, boundary: index,
                                                availableHeight: availableHeight)
                Capsule().fill(Color.accentColor)
                    .frame(width: max(0, geo.size.width), height: 2)
                    .position(x: geo.size.width / 2, y: y)
            case .column(let rowIndex, let boundary):
                let x = verticalDividerCenter(preview, row: rowIndex, boundary: boundary,
                                              totalWidth: geo.size.width)
                let extent = rowExtent(committed, row: rowIndex, availableHeight: availableHeight)
                Capsule().fill(Color.accentColor)
                    .frame(width: 2, height: max(0, extent.height))
                    .position(x: x, y: extent.top + extent.height / 2)
            }
        }
    }

    /// Drag gesture for the horizontal divider that resizes rows `index`/`index+1`.
    private func rowDrag(boundary index: Int, shape: [Int],
                         availableHeight: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                activeDivider = .row(index)
                let anchor = anchorLayout(for: shape)
                let minFraction = Double(minTileHeight / availableHeight)
                let delta = Double(value.translation.height / availableHeight)
                var next = anchor
                next.rowFractions = TileLayout.resized(anchor.rowFractions, boundary: index,
                                                       by: delta, minFraction: minFraction)
                dragLayout = next
            }
            .onEnded { _ in commitDrag() }
    }

    /// Drag gesture for a vertical divider that resizes columns `index`/`index+1`
    /// within `rowIndex`.
    private func columnDrag(row rowIndex: Int, boundary index: Int,
                            shape: [Int], availableWidth: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                activeDivider = .column(row: rowIndex, boundary: index)
                let anchor = anchorLayout(for: shape)
                let minFraction = Double(minTileWidth / availableWidth)
                let delta = Double(value.translation.width / availableWidth)
                var next = anchor
                next.columnFractions[rowIndex] = TileLayout.resized(
                    anchor.columnFractions[rowIndex], boundary: index,
                    by: delta, minFraction: minFraction)
                dragLayout = next
            }
            .onEnded { _ in commitDrag() }
    }

    /// The layout a drag is measured against — captured once when the drag starts.
    private func anchorLayout(for shape: [Int]) -> TileLayout {
        if let dragAnchor { return dragAnchor }
        let anchor = (dragLayout ?? sessions.currentTileLayout).conformed(to: shape)
        dragAnchor = anchor
        return anchor
    }

    /// Commit the in-progress drag to the workspace (a single resize) and end it.
    private func commitDrag() {
        if let dragLayout { sessions.updateTileLayout(dragLayout) }
        dragLayout = nil
        dragAnchor = nil
        activeDivider = nil
    }

    /// Sum of the first `index + 1` fractions (0 for a negative index).
    private func cumulative(_ fractions: [Double], through index: Int) -> CGFloat {
        guard index >= 0 else { return 0 }
        return CGFloat(fractions.prefix(index + 1).reduce(0, +))
    }

    /// Center Y of the horizontal divider after row `index`, for layout `L`.
    private func horizontalDividerCenter(_ L: TileLayout, boundary index: Int,
                                         availableHeight: CGFloat) -> CGFloat {
        cumulative(L.rowFractions, through: index) * availableHeight
            + CGFloat(index) * dividerThickness + dividerThickness / 2
    }

    /// Center X of the vertical divider after column `boundary` in row `row`.
    private func verticalDividerCenter(_ L: TileLayout, row: Int, boundary: Int,
                                       totalWidth: CGFloat) -> CGFloat {
        let columns = L.columnFractions[row].count
        let availableWidth = max(1, totalWidth - dividerThickness * CGFloat(max(0, columns - 1)))
        return cumulative(L.columnFractions[row], through: boundary) * availableWidth
            + CGFloat(boundary) * dividerThickness + dividerThickness / 2
    }

    /// Top and height of row `row` — the cross-axis extent for a vertical guide.
    private func rowExtent(_ L: TileLayout, row: Int,
                           availableHeight: CGFloat) -> (top: CGFloat, height: CGFloat) {
        let top = cumulative(L.rowFractions, through: row - 1) * availableHeight
            + CGFloat(row) * dividerThickness
        let height = CGFloat(L.rowFractions[row]) * availableHeight
        return (top, height)
    }
}

/// A thin draggable separator between tiles, with a subtle line that brightens on
/// hover and a matching resize cursor. The drag gesture itself is supplied by the
/// grid, which knows the geometry and which panes to resize.
private struct TileDivider: View {
    enum Orientation { case horizontal, vertical }
    let orientation: Orientation
    /// True while this divider is being dragged — keeps it highlighted without
    /// depending on hover, which flickers as the pointer leaves during a drag.
    var isActive: Bool = false
    @State private var hovering = false

    private var lineOpacity: Double {
        if isActive { return 0.5 }
        return hovering ? 0.6 : 0.18
    }

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .overlay(
                Rectangle()
                    .fill(Color.secondary.opacity(lineOpacity))
                    .frame(width: orientation == .vertical ? 1 : nil,
                           height: orientation == .horizontal ? 1 : nil)
            )
            // AppKit cursor rect — it balances enter/exit reliably even if the
            // divider is torn down mid-hover (e.g. when the grid rebuilds), unlike
            // manual NSCursor push/pop which could leave a stuck resize cursor.
            .overlay(ResizeCursorRect(orientation: orientation))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Shows the appropriate resize cursor over its bounds via an AppKit cursor rect.
private struct ResizeCursorRect: NSViewRepresentable {
    let orientation: TileDivider.Orientation

    func makeNSView(context: Context) -> CursorRectView {
        let view = CursorRectView()
        view.cursor = orientation == .horizontal ? .resizeUpDown : .resizeLeftRight
        return view
    }

    func updateNSView(_ nsView: CursorRectView, context: Context) {
        nsView.cursor = orientation == .horizontal ? .resizeUpDown : .resizeLeftRight
    }

    final class CursorRectView: NSView {
        var cursor: NSCursor = .arrow {
            didSet {
                if cursor != oldValue { window?.invalidateCursorRects(for: self) }
            }
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    }
}

/// One terminal in tiled view: a slim header (status, title, detach, close) above
/// the live terminal, framed and click-to-select.
private struct TerminalTile: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject var sessions: TerminalSessionManager
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Image(systemName: session.symbolName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(session.title)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if session.supportsCommandHistory {
                    HistoryMenuButton(session: session)
                        .font(.caption2)
                        .menuIndicator(.hidden)
                }
                if session.isRunning {
                    Button {
                        session.disconnect()
                    } label: {
                        Image(systemName: "bolt.horizontal.circle").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help(session.isRemote ? "Disconnect this tunnel" : "Stop this terminal")
                }
                Button {
                    DetachedTerminalController.shared.detach(session)
                } label: {
                    Image(systemName: "macwindow.badge.plus").font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Detach into new window")
                Button {
                    sessions.close(session)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help("Close tab")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)
            .contentShape(Rectangle())
            .onTapGesture { sessions.select(session) }
            .contextMenu {
                TerminalTabContextMenu(
                    session: session,
                    onDetach: { DetachedTerminalController.shared.detach(session) },
                    onClose: { sessions.close(session) })
            }

            Divider()
            TerminalContainer(session: session)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.8)
                                         : Color.secondary.opacity(0.25),
                              lineWidth: isSelected ? 2 : 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusColor: Color {
        if session.isRunning { return .green }
        if let code = session.exitCode, code != 0 { return .red }
        return .secondary
    }
}

struct TerminalContainer: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject var sessions: TerminalSessionManager
    /// Whether this container is the one visible on screen. Passed to the
    /// terminal so only the visible tab accepts file drops (the center area
    /// keeps every tab mounted and stacked).
    var isVisible: Bool = true

    var body: some View {
        if session.kind == .sftp {
            SFTPBrowserView(session: session)
        } else if session.kind == .vnc {
            VNCConsoleView(session: session)
        } else if session.kind == .web {
            WebTabView(session: session)
        } else if session.kind == .mqtt {
            MQTTExplorerView(session: session)
        } else if session.kind == .redis {
            RedisBrowserView(session: session)
        } else if session.kind == .finder {
            FinderBrowserView(session: session)
        } else if session.kind == .editor {
            TextEditorTabView(session: session)
        } else if session.kind == .spreadsheet {
            SpreadsheetTabView(session: session)
        } else {
            terminal
        }
    }

    private var terminal: some View {
        ZStack(alignment: .top) {
            TerminalViewRepresentable(session: session, isActive: isVisible)
                .id(session.id)

            if !session.isRunning {
                ExitBanner(
                    session: session,
                    onReconnect: { session.restart() },
                    onClose: { sessions.close(session) }
                )
                .padding(10)
            }
        }
    }
}

private struct ExitBanner: View {
    @ObservedObject var session: TerminalSession
    var onReconnect: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(exitText).fontWeight(.semibold)
                Text(session.commandPreview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Reconnect", action: onReconnect)
                .buttonStyle(.borderedProminent)
            Button("Close", action: onClose)
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8, y: 2)
    }

    private var exitText: String {
        if let code = session.exitCode, code != 0 {
            return "Session ended — exit code \(code)"
        }
        return "Session ended"
    }
}

private struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                Text("SSH Tunnel Manager")
                    .font(.largeTitle.bold())
                Text("Resume your last session, open a local terminal, connect to a server, or click a profile.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            WelcomeLaunchOptions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

/// The launch actions shown on the welcome screen — a row of "new tab" buttons,
/// the "Connect to a server" shortcuts, the profiles grid and the recently-closed
/// list. Extracted into its own view so the all-docked center (`DockedOnlyCenter`)
/// can offer the same full set of starting points instead of just a single
/// "New Local Terminal" button.
private struct WelcomeLaunchOptions: View {
    @EnvironmentObject var sessions: TerminalSessionManager
    @EnvironmentObject var store: ProfileStore

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 280), spacing: 10)]

    /// Whether to offer "Resume Last Session". Only the welcome screen sets this
    /// true; the docked-only center already has open (docked) tabs, so it never
    /// applies there.
    var showsResume: Bool = true

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                let saved = sessions.savedSessionCount
                if showsResume, saved > 0 && sessions.sessions.isEmpty {
                    Button {
                        sessions.restoreSavedSessions()
                    } label: {
                        Label("Resume Last Session (\(saved) tab\(saved == 1 ? "" : "s"))",
                              systemImage: "arrow.clockwise.circle.fill")
                    }
                    .controlSize(.large)
                    .help("Reopen the tabs that were open when you last quit")
                }
                Button {
                    sessions.openLocalShell()
                } label: {
                    Label("New Local Terminal", systemImage: "terminal")
                }
                .controlSize(.large)

                Button {
                    sessions.openBlankWeb()
                } label: {
                    Label("New Browser Tab", systemImage: "globe")
                }
                .controlSize(.large)

                Button {
                    sessions.openFinder()
                } label: {
                    Label("New Finder Tab", systemImage: "folder")
                }
                .controlSize(.large)

                Button {
                    sessions.openTextEditor()
                } label: {
                    Label("New Text Editor", systemImage: "doc.text")
                }
                .controlSize(.large)

                Button {
                    sessions.openSpreadsheet()
                } label: {
                    Label("New Spreadsheet", systemImage: "tablecells")
                }
                .controlSize(.large)
            }

            // Quick, profile-free connections to a server (the blank-workspace
            // shortcuts for the remote tab kinds).
            VStack(spacing: 8) {
                Text("Connect to a server")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button {
                        RemoteConnectionModel.shared.present(.ssh)
                    } label: {
                        Label("Remote Terminal", systemImage: "network")
                    }
                    .controlSize(.large)
                    .help("Open an SSH terminal on a server")

                    Button {
                        RemoteConnectionModel.shared.present(.sftp)
                    } label: {
                        Label("SFTP", systemImage: "arrow.up.arrow.down")
                    }
                    .controlSize(.large)
                    .help("Browse and transfer files over SFTP")

                    Button {
                        VNCConnectionModel.shared.present()
                    } label: {
                        Label("VNC", systemImage: "display")
                    }
                    .controlSize(.large)
                    .help("View a computer’s screen over VNC")

                    Button {
                        ServiceConnectionModel.shared.present(.mqtt)
                    } label: {
                        Label("MQTT", systemImage: ForwardCategory.mqtt.symbol)
                    }
                    .controlSize(.large)
                    .help("Browse an MQTT broker")

                    Button {
                        ServiceConnectionModel.shared.present(.redis)
                    } label: {
                        Label("Redis", systemImage: ForwardCategory.redis.symbol)
                    }
                    .controlSize(.large)
                    .help("Browse a Redis server")

                    Button {
                        ZeroTierBrowserModel.shared.present()
                    } label: {
                        Label("ZeroTier", systemImage: "globe.americas.fill")
                    }
                    .controlSize(.large)
                    .help("Browse and connect to devices on your ZeroTier networks")
                }
            }

            if !store.profiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Profiles")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(store.profiles) { profile in
                                ProfileLaunchButton(profile: profile)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 280)
                }
                .frame(maxWidth: 580)
            }

            if !sessions.recentlyClosed.isEmpty {
                RecentlyClosedSection()
                    .frame(maxWidth: 580)
            }
        }
    }
}

/// The welcome screen's "Recently Closed" list — tabs and whole workspaces the
/// user closed without saving, each reopenable with one click.
private struct RecentlyClosedSection: View {
    @EnvironmentObject var sessions: TerminalSessionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recently Closed")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    sessions.clearRecentlyClosed()
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.tint)
                .help("Forget every recently-closed item")
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(sessions.recentlyClosed) { item in
                        RecentlyClosedRow(item: item)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 200)
        }
    }
}

/// One clickable row in the "Recently Closed" list. Click reopens it; the menu
/// button forgets it.
private struct RecentlyClosedRow: View {
    @EnvironmentObject var sessions: TerminalSessionManager
    let item: ClosedItem

    var body: some View {
        HStack(spacing: 10) {
            Button {
                sessions.reopenClosedItem(item)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: item.symbol)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .contentShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .help(item.kind == .workspace ? "Reopen this workspace" : "Reopen this tab")
            .contextMenu {
                Button {
                    sessions.reopenClosedItem(item)
                } label: {
                    Label("Reopen", systemImage: "arrow.uturn.backward")
                }
                Button(role: .destructive) {
                    sessions.removeClosedItem(item)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }
}

/// A clickable card on the welcome screen that connects a profile. Right-click
/// for SFTP / VNC on remote profiles.
private struct ProfileLaunchButton: View {
    @EnvironmentObject var sessions: TerminalSessionManager
    let profile: SSHProfile

    var body: some View {
        Button {
            sessions.connect(profile: profile)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: profile.displayIcon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(profile.rowSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                sessions.connect(profile: profile)
            } label: {
                Label("Connect", systemImage: "play.fill")
            }
            if !profile.isLocal {
                Button {
                    sessions.connectSFTP(profile: profile)
                } label: {
                    Label("Open SFTP", systemImage: "arrow.up.arrow.down")
                }
                Button {
                    sessions.connectVNC(profile: profile)
                } label: {
                    Label("Open VNC", systemImage: "display")
                }
                Button {
                    sessions.setUpKeyLogin(profile: profile)
                } label: {
                    Label("Set Up Passwordless Login…", systemImage: "key")
                }
            }
        }
        .help(profile.isLocal ? "Open this local profile" : "Connect this SSH tunnel")
    }
}

/// Shown when every open terminal has been detached into its own window.
private struct AllDetachedView: View {
    @EnvironmentObject var sessions: TerminalSessionManager

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 46))
                .foregroundStyle(.tint)
            Text("All terminals are in separate windows")
                .font(.title3.weight(.semibold))
            Text("\(sessions.detachedSessionIDs.count) detached window(s) — their tunnels are still running. Close a window to bring its tab back, or open a new terminal here.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button {
                sessions.openLocalShell()
            } label: {
                Label("New Local Terminal", systemImage: "terminal")
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
