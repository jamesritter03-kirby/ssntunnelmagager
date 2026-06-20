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
                            if !profile.isLocal {
                                Button("Open SFTP") { sessions.connectSFTP(profile: profile) }
                                Button("Open VNC") { sessions.connectVNC(profile: profile) }
                            }
                            if !profile.links.isEmpty {
                                Menu("Open Link") {
                                    ForEach(profile.links) { link in
                                        Button(link.displayLabel) {
                                            sessions.openLink(link, profile: profile)
                                        }
                                        .disabled(link.normalizedURL == nil)
                                    }
                                }
                            }
                            if !profile.categorizedForwards.isEmpty {
                                Menu("Open Service") {
                                    ForEach(profile.categorizedForwards) { forward in
                                        Button {
                                            sessions.openService(forward.category,
                                                                 forward: forward, profile: profile)
                                        } label: {
                                            Label("Open \(forward.category.title) (:\(forward.listenPort))",
                                                  systemImage: forward.category.symbol)
                                        }
                                    }
                                }
                            }
                            Button("Edit…") { onEdit(profile) }
                            Button("Duplicate") { store.duplicate(profile) }
                            Button("Export…") {
                                ProfileTransfer.exportFlow([profile],
                                                           suggestedName: ProfileTransfer.fileName(for: profile))
                            }
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

                Menu {
                    Button {
                        ProfileTransfer.importFlow(into: store)
                    } label: {
                        Label("Import Profiles…", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        ProfileTransfer.exportFlow(store.profiles, suggestedName: "SSH Tunnels.json")
                    } label: {
                        Label("Export All Profiles…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.profiles.isEmpty)

                    if let id = selectedProfileID,
                       let profile = store.profiles.first(where: { $0.id == id }) {
                        Divider()
                        Button {
                            ProfileTransfer.exportFlow([profile],
                                                       suggestedName: ProfileTransfer.fileName(for: profile))
                        } label: {
                            Label("Export “\(profile.name)”…", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Import or export profiles")

                if let id = selectedProfileID, let profile = store.profiles.first(where: { $0.id == id }) {
                    if !profile.isLocal {
                        Button {
                            sessions.connectSFTP(profile: profile)
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .help("Open SFTP file transfer for the selected profile")

                        Button {
                            sessions.connectVNC(profile: profile)
                        } label: {
                            Image(systemName: "display")
                        }
                        .help("Open VNC screen sharing (over SSH) for the selected profile")
                    }

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
            Image(systemName: profile.displayIcon)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(profile.rowSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !profile.isLocal, !profile.forwards.isEmpty {
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
