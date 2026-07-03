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

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebar.columnVisibility) {
            SidebarView(
                selectedProfileID: $selectedProfileID,
                onConnect: { sessions.connect(profile: $0) },
                onEdit: { duplicatedFromName = nil; editingProfile = $0 },
                onNew: { duplicatedFromName = nil; editingProfile = SSHProfile() },
                onDuplicate: { original in
                    let copy = store.duplicate(original)
                    duplicatedFromName = original.name
                    editingProfile = copy
                }
            )
            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 420)
            .modifier(RemoveDefaultSidebarToggle())
        } detail: {
            TerminalAreaView()
                .navigationTitle("SSH Tunnel Manager")
                .modifier(ReliableSidebarToggleToolbar())
        }
        .background(WindowAccessor())
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
