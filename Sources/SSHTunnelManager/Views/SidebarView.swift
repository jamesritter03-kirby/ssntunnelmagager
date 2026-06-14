import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var sessions: TerminalSessionManager
    @Binding var selectedProfileID: UUID?

    var onConnect: (SSHProfile) -> Void
    var onEdit: (SSHProfile) -> Void
    var onNew: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedProfileID) {
                Section("Profiles") {
                    if store.profiles.isEmpty {
                        Text("No profiles yet.\nClick + to add one.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                    ForEach(store.profiles) { profile in
                        ProfileRow(
                            profile: profile,
                            onConnect: { onConnect(profile) }
                        )
                        .tag(profile.id)
                        .contextMenu {
                            Button("Connect") { onConnect(profile) }
                            Button("Edit…") { onEdit(profile) }
                            Button("Duplicate") { store.duplicate(profile) }
                            Divider()
                            Button("Delete", role: .destructive) { store.delete(profile) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 8) {
                Button {
                    sessions.openLocalShell()
                } label: {
                    Label("Local Terminal", systemImage: "terminal")
                }
                .help("Open a local shell (⌘T)")

                Spacer()

                if let id = selectedProfileID, let profile = store.profiles.first(where: { $0.id == id }) {
                    Button {
                        onEdit(profile)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .help("Edit selected profile")
                }

                Button(action: onNew) {
                    Image(systemName: "plus")
                }
                .help("Add a new profile")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .toolbar {
            ToolbarItem {
                Button(action: onNew) {
                    Label("New Profile", systemImage: "plus")
                }
                .help("Add a new profile")
            }
        }
    }
}

struct ProfileRow: View {
    let profile: SSHProfile
    var onConnect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(profile.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !profile.forwards.isEmpty {
                    Text(profile.forwards.map(\.summary).joined(separator: "  ·  "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button(action: onConnect) {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Connect")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onConnect)
    }
}
