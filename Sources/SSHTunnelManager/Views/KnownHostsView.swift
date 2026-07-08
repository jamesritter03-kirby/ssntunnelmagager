import SwiftUI

/// Presents the known-hosts manager sheet (mirrors the ZeroTier browser model).
final class KnownHostsModel: ObservableObject {
    static let shared = KnownHostsModel()
    private init() {}

    @Published var isPresented = false
    func present() { isPresented = true }
}

/// A simple manager for `~/.ssh/known_hosts`: list the stored host keys and
/// remove a stale/changed one without dropping to a shell.
struct KnownHostsView: View {
    @StateObject private var store = KnownHostsStore()
    @State private var filter = ""
    @State private var selection: Set<UUID> = []
    @Environment(\.dismiss) private var dismiss

    private var filtered: [KnownHostEntry] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return store.entries }
        return store.entries.filter {
            $0.hostLabel.lowercased().contains(needle) || $0.keyType.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 460)
        .onAppear { store.reload() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Known Hosts").font(.headline)
                Text("Host keys your Mac has accepted (~/.ssh/known_hosts)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { store.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload")
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        if store.entries.isEmpty {
            EmptyStateView(icon: "checkmark.shield",
                           title: store.fileExists ? "No host keys stored" : "No known_hosts file",
                           message: store.fileExists
                             ? "Hosts you connect to will appear here."
                             : "You haven't accepted any SSH host keys yet.")
        } else {
            List(selection: $selection) {
                ForEach(filtered) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.isHashed ? "lock.doc" : "server.rack")
                            .foregroundStyle(entry.isHashed ? Color.secondary : Color.accentColor)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.hostLabel).lineLimit(1).truncationMode(.middle)
                            Text(entry.keyType).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            store.remove(entry)
                            selection.remove(entry.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this host key")
                    }
                    .padding(.vertical, 2)
                    .tag(entry.id)
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            TextField("Filter hosts…", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            if let message = store.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
            Button("Remove Selected", role: .destructive) {
                let doomed = store.entries.filter { selection.contains($0.id) }
                store.remove(doomed)
                selection.removeAll()
            }
            .disabled(selection.isEmpty)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }
}
