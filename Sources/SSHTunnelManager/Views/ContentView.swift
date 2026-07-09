import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var sessions: TerminalSessionManager
    @ObservedObject private var palette = CommandPaletteModel.shared

    @State private var selectedProfileID: UUID?
    @State private var editingProfile: SSHProfile?
    /// When the editor was opened by **Duplicate**, the source profile's name, so
    /// the editor can show a short “finish setting up this copy” wizard.
    @State private var duplicatedFromName: String?
    @ObservedObject private var sidebar = SidebarModel.shared
    @ObservedObject private var serviceConnection = ServiceConnectionModel.shared
    @ObservedObject private var vncConnection = VNCConnectionModel.shared
    @ObservedObject private var remoteConnection = RemoteConnectionModel.shared
    @ObservedObject private var zerotier = ZeroTierBrowserModel.shared
    @ObservedObject private var editCoordinator = ProfileEditCoordinator.shared
    @ObservedObject private var editConnection = EditConnectionModel.shared
    @ObservedObject private var knownHosts = KnownHostsModel.shared
    @ObservedObject private var addForward = AddForwardModel.shared

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebar.columnVisibility) {
            SidebarView(
                selectedProfileID: $selectedProfileID,
                onConnect: { profile in
                    // Always connect using the live store copy so a stale row/menu
                    // value can never connect to the wrong host.
                    let live = store.profiles.first(where: { $0.id == profile.id }) ?? profile
                    sessions.connect(profile: live)
                },
                onEdit: { duplicatedFromName = nil; editingProfile = $0 },
                onNew: { duplicatedFromName = nil; editingProfile = SSHProfile() },
                onDuplicate: { original in
                    // The duplicate shares the source's saved-workspace template
                    // (if any). Templates are read-only at connect time — each
                    // profile builds its *own* live workspace from it — so sharing
                    // is safe and avoids creating a stray duplicate workspace here.
                    // The template is forked lazily on save, and only if the copy's
                    // host actually changes (see ProfileEditorView.commitSave).
                    let copy = store.duplicate(original)
                    duplicatedFromName = original.name
                    editingProfile = copy
                }
            )
            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 420)
            .modifier(RemoveDefaultSidebarToggle())
        } detail: {
            TerminalAreaView()
                .navigationTitle("Remote Stuff")
                .modifier(ReliableSidebarToggleToolbar())
                // Keep the window's unified toolbar permanently present. Presenting
                // or dismissing a sheet (e.g. the profile editor) otherwise lets
                // AppKit briefly collapse the toolbar, which re-measures the
                // titlebar and nudges *all* window content down a few pixels — the
                // shift seen on both Save and Cancel. Pinning it visible removes the
                // collapse, so the content never moves.
                .toolbar(.visible, for: .windowToolbar)
        }
        .background(WindowAccessor())
        .task {
            // Load ZeroTier devices (if an account exists) so profiles whose host
            // is a ZeroTier IP can show an online/offline glyph in the sidebar and
            // on the welcome screen. No-op when no ZeroTier account is configured.
            await ZeroTierStore.shared.loadIfNeeded()
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditorView(
                profile: profile,
                duplicatedFromName: duplicatedFromName,
                onSave: { saved in
                    store.update(saved)
                    sessions.applyTheme(TerminalTheme.theme(id: saved.theme), toProfileID: saved.id)
                    selectedProfileID = saved.id
                    editingProfile = nil
                    duplicatedFromName = nil
                },
                onCancel: { editingProfile = nil; duplicatedFromName = nil }
            )
            .frame(minWidth: 680, idealWidth: 720, minHeight: 540)
        }
        .onChange(of: editCoordinator.profileToEdit) { requested in
            // A profile the app asked us to edit (e.g. one just created by “Save
            // Workspace as Profile”): open the editor for it, then clear the request.
            guard let requested else { return }
            duplicatedFromName = nil
            editingProfile = requested
            editCoordinator.profileToEdit = nil
        }
        .onChange(of: editingProfile) { profile in
            // Presenting or dismissing the editor sheet lets the unified toolbar
            // re-measure, which nudges the whole window down a few points — seen on
            // both Save and Cancel. Snapshot the frame while the sheet is open and,
            // as it closes, actively hold the window there for the length of the
            // dismiss so the shift never reaches the screen (instead of a delayed
            // one-shot restore, which just bounced).
            if profile != nil {
                WindowManager.shared.rememberFrame()
            } else {
                WindowManager.shared.beginFrameGuard()
            }
        }
        .sheet(isPresented: $palette.isPresented) {
            CommandPaletteView(palette: palette)
                .environmentObject(store)
                .environmentObject(sessions)
        }
        .sheet(isPresented: $serviceConnection.isPresented) {
            ServiceConnectionView(model: serviceConnection)
                .environmentObject(sessions)
        }
        .sheet(isPresented: $editConnection.isPresented) {
            EditConnectionView(model: editConnection)
                .environmentObject(sessions)
        }
        .sheet(isPresented: $vncConnection.isPresented) {
            VNCConnectionView(model: vncConnection)
                .environmentObject(sessions)
        }
        .sheet(isPresented: $remoteConnection.isPresented) {
            RemoteConnectionView(model: remoteConnection)
                .environmentObject(sessions)
        }
        .sheet(isPresented: $zerotier.isPresented) {
            ZeroTierBrowserView()
                .environmentObject(sessions)
        }
        .sheet(isPresented: $knownHosts.isPresented) {
            KnownHostsView()
        }
        .sheet(isPresented: $addForward.isPresented) {
            AddForwardView(model: addForward)
                .environmentObject(sessions)
        }
        .alert("Save changes to this profile before quitting?",
               isPresented: $editCoordinator.showQuitConfirmation) {
            Button("Save") { editCoordinator.saveAndQuit() }
                .disabled(!editCoordinator.canSave)
            Button("Don't Save", role: .destructive) { editCoordinator.discardAndQuit() }
            Button("Cancel", role: .cancel) { editCoordinator.cancelQuit() }
        } message: {
            Text("If you don't save, the changes you made to this profile will be lost.")
        }
    }
}

// MARK: - Reliable sidebar toggle
//
// `NavigationSplitView` auto-injects a show/hide-sidebar button into the toolbar,
// but AppKit sometimes drops it (e.g. after the sidebar is collapsed by dragging
// or a sheet is dismissed) — leaving the View-menu item (⌃⌘S) as the only way
// back. On macOS 14.5+ we remove that unreliable system button and supply our
// own, driven by the same `SidebarModel` state as the menu item, so it's always
// present and never duplicated. Older systems keep the system button unchanged.

/// Removes the automatically-generated sidebar toggle from the sidebar column
/// (macOS 14.5+), so it can't be shown alongside our custom one below.
private struct RemoveDefaultSidebarToggle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.5, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

/// Adds an always-present sidebar toggle to the detail column's leading toolbar
/// area (macOS 14.5+). Living in the detail toolbar — which never collapses —
/// means it can't disappear the way the sidebar-owned system button does.
private struct ReliableSidebarToggleToolbar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.5, *) {
            content.toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        SidebarModel.shared.toggle()
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .help("Show or hide the sidebar (⌃⌘S)")
                }
            }
        } else {
            content
        }
    }
}
