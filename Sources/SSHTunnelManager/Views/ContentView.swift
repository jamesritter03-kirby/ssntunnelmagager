import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var sessions: TerminalSessionManager
    @ObservedObject private var palette = CommandPaletteModel.shared

    @State private var selectedProfileID: UUID?
    @State private var editingProfile: SSHProfile?
    @ObservedObject private var sidebar = SidebarModel.shared
    @ObservedObject private var serviceConnection = ServiceConnectionModel.shared
    @ObservedObject private var vncConnection = VNCConnectionModel.shared
    @ObservedObject private var remoteConnection = RemoteConnectionModel.shared
    @ObservedObject private var editCoordinator = ProfileEditCoordinator.shared

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebar.columnVisibility) {
            SidebarView(
                selectedProfileID: $selectedProfileID,
                onConnect: { sessions.connect(profile: $0) },
                onEdit: { editingProfile = $0 },
                onNew: { editingProfile = SSHProfile() }
            )
            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 420)
        } detail: {
            TerminalAreaView()
                .navigationTitle("SSH Tunnel Manager")
        }
        .background(WindowAccessor())
        .sheet(item: $editingProfile) { profile in
            ProfileEditorView(
                profile: profile,
                onSave: { saved in
                    store.update(saved)
                    sessions.applyTheme(TerminalTheme.theme(id: saved.theme), toProfileID: saved.id)
                    selectedProfileID = saved.id
                    editingProfile = nil
                },
                onCancel: { editingProfile = nil }
            )
            .frame(minWidth: 560, minHeight: 520)
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
        .sheet(isPresented: $vncConnection.isPresented) {
            VNCConnectionView(model: vncConnection)
                .environmentObject(sessions)
        }
        .sheet(isPresented: $remoteConnection.isPresented) {
            RemoteConnectionView(model: remoteConnection)
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
