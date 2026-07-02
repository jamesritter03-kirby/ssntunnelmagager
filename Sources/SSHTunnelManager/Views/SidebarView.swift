import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var sessions: TerminalSessionManager
    @Binding var selectedProfileID: UUID?

    var onConnect: (SSHProfile) -> Void
    var onEdit: (SSHProfile) -> Void
    var onNew: () -> Void
    var onDuplicate: (SSHProfile) -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedProfileID) {
                Section("Profiles") {
                    if store.profiles.isEmpty {
                        EmptyStateView(icon: "person.crop.rectangle.stack",
                                       title: "No profiles yet",
                                       message: "Click + to add one.")
                    }
                    ForEach(store.profiles) { profile in
                        ProfileRow(
                            profile: profile,
                            isConnected: sessions.isConnected(profile: profile),
                            onConnect: { onConnect(profile) },
                            onDisconnect: { sessions.disconnect(profile: profile) }
                        )
                        .tag(profile.id)
                        .contextMenu {
                            Button {
                                onConnect(profile)
                            } label: {
                                Label("Connect", systemImage: "play.fill")
                            }
                            Button {
                                sessions.disconnect(profile: profile)
                            } label: {
                                Label("Disconnect", systemImage: "stop.fill")
                            }
                            .disabled(!sessions.isConnected(profile: profile))
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
                            if !profile.links.isEmpty {
                                Menu {
                                    ForEach(profile.links) { link in
                                        Button(link.displayLabel) {
                                            sessions.openLink(link, profile: profile)
                                        }
                                        .disabled(link.normalizedURL == nil)
                                    }
                                } label: {
                                    Label("Open Link", systemImage: "link")
                                }
                            }
                            if !profile.categorizedForwards.isEmpty {
                                Menu {
                                    ForEach(profile.categorizedForwards) { forward in
                                        Button {
                                            sessions.openService(forward.category,
                                                                 forward: forward, profile: profile)
                                        } label: {
                                            Label(forward.trimmedName.isEmpty
                                                  ? "Open \(forward.category.title) (:\(forward.listenPort))"
                                                  : "\(forward.trimmedName) (:\(forward.listenPort))",
                                                  systemImage: forward.category.symbol)
                                        }
                                    }
                                } label: {
                                    Label("Open Service", systemImage: "bolt.horizontal")
                                }
                            }
                            Button {
                                onEdit(profile)
                            } label: {
                                Label("Edit…", systemImage: "pencil")
                            }
                            Button {
                                onDuplicate(profile)
                            } label: {
                                Label("Duplicate…", systemImage: "plus.square.on.square")
                            }
                            Button {
                                ProfileTransfer.exportFlow([profile],
                                                           suggestedName: ProfileTransfer.fileName(for: profile))
                            } label: {
                                Label("Export…", systemImage: "square.and.arrow.up")
                            }
                            Divider()
                            Button(role: .destructive) {
                                store.delete(profile)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
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
                    Image(systemName: "terminal")
                }
                .help("Open a local shell (⌘T)")

                Button {
                    ZeroTierBrowserModel.shared.present()
                } label: {
                    Image(systemName: "globe.americas.fill")
                }
                .help("Browse and connect to devices on your ZeroTier networks")

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

                        Button {
                            sessions.setUpKeyLogin(profile: profile)
                        } label: {
                            Image(systemName: "key")
                        }
                        .help("Set up passwordless login (copy your SSH key with ssh-copy-id)")
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
    var isConnected: Bool = false
    var onConnect: () -> Void
    var onDisconnect: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: profile.displayIcon)
                .foregroundStyle(.tint)
                .overlay(alignment: .bottomTrailing) {
                    if isConnected {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor),
                                                           lineWidth: 1.5))
                            .offset(x: 3, y: 2)
                    }
                }
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
            Button(action: isConnected ? onDisconnect : onConnect) {
                Image(systemName: isConnected ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(isConnected ? Color.red : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help(isConnected ? "Disconnect" : "Connect")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onConnect)
    }
}
