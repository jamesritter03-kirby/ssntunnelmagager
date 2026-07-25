import SwiftUI

/// Presentation state for the **Sync Profiles with Git** sheet — mirrors the other
/// singleton dialog models in the app (`present()` flips `isPresented`, which a
/// `.sheet` in `ContentView` observes).
@MainActor
final class GitSyncModel: ObservableObject {
    static let shared = GitSyncModel()
    @Published var isPresented = false
    func present() { isPresented = true }
    private init() {}
}

/// Sheet that syncs the user's `profiles.json` with a Git repository (e.g. a
/// private GitHub repo) so profiles can be shared across machines. **Push** saves
/// and uploads the current profiles; **Pull** downloads them and replaces the
/// local set. Wraps `GitProfileSync`.
struct GitSyncView: View {
    @EnvironmentObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss

    // A single sync engine bound to the live store file, kept for the sheet's lifetime.
    @StateObject private var engine = GitSyncEngine()

    @State private var remoteUrl = ""
    @State private var branch = "main"
    @State private var commitMessage = ""
    @State private var log = ""
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DialogHeader(
                icon: "arrow.triangle.2.circlepath",
                title: "Sync Profiles with Git",
                subtitle: "Share profiles across machines through a Git repository."
            )

            Text("Push saves and uploads your current profiles; Pull downloads them and replaces your local profiles. Passwords are never included — they stay in your Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Remote URL")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    TextField("git@github.com:user/remote-profiles.git (optional)", text: $remoteUrl)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Branch")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    TextField("main", text: $branch)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Commit message")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    TextField("Optional — used when pushing", text: $commitMessage)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 8) {
                Button {
                    run(reloadOnSuccess: true) { await engine.sync.pull() }
                } label: {
                    Label("Pull (import)", systemImage: "arrow.down.circle")
                }
                Button {
                    run { await engine.sync.push(commitMessage: commitMessage) }
                } label: {
                    Label("Push (share)", systemImage: "arrow.up.circle")
                }
                .buttonStyle(.borderedProminent)

                Button("Init / Clone") {
                    run { await engine.sync.initOrClone() }
                }
                Button("Status") {
                    run { await engine.sync.status() }
                }

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                    Text("Working…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(isBusy)

            Text("Local working copy: \(engine.sync.repoDirectory)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            GroupBox {
                ScrollView {
                    Text(log.isEmpty ? "Ready." : log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(minHeight: 160)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520)
        .onAppear {
            remoteUrl = engine.sync.config.remoteUrl
            branch = engine.sync.config.branch
        }
    }

    /// Persist config, run the operation off the main actor, then show its log.
    private func run(reloadOnSuccess: Bool = false, _ op: @escaping () async -> GitSyncResult) {
        guard !isBusy else { return }
        isBusy = true
        engine.sync.saveConfig(remoteUrl: remoteUrl, branch: branch)
        Task {
            let result = await op()
            await MainActor.run {
                log = result.log
                if result.success && reloadOnSuccess {
                    store.reloadFromDisk()
                }
                isBusy = false
            }
        }
    }
}

/// Holds the `GitProfileSync` engine bound to the live store file. A tiny
/// `ObservableObject` wrapper so the sheet can own it via `@StateObject`.
@MainActor
final class GitSyncEngine: ObservableObject {
    let sync = GitProfileSync(profilesPath: ProfileStore.shared.storagePath)
}
