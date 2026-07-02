import SwiftUI

/// The two profile-free remote connection kinds the "new connection" sheet can
/// open: an interactive SSH **terminal** or an **SFTP** file browser.
enum RemoteConnectionKind {
    case ssh
    case sftp

    var title: String {
        switch self {
        case .ssh:  return "New Remote Terminal"
        case .sftp: return "New SFTP Connection"
        }
    }

    var blurb: String {
        switch self {
        case .ssh:  return "Open an SSH terminal on a server."
        case .sftp: return "Browse and transfer files over SFTP."
        }
    }

    var symbol: String {
        switch self {
        case .ssh:  return "network"
        case .sftp: return "arrow.up.arrow.down"
        }
    }
}

/// Drives the "new remote connection" setup sheet for ad-hoc **SSH** and
/// **SFTP** tabs. A singleton so the tab-bar **+** menu, the **New** menu and the
/// welcome screen can all trigger it while the main window presents it. Mirrors
/// `VNCConnectionModel` / `ServiceConnectionModel`.
final class RemoteConnectionModel: ObservableObject {
    static let shared = RemoteConnectionModel()
    private init() {}

    @Published var isPresented = false
    @Published var kind: RemoteConnectionKind = .ssh
    @Published var host = ""
    @Published var port = ""
    @Published var username = ""
    @Published var password = ""

    /// Present the sheet for `kind`, pre-filled with the default SSH port (22).
    func present(_ kind: RemoteConnectionKind) {
        self.kind = kind
        host = ""
        port = "22"
        username = ""
        password = ""
        isPresented = true
    }
}

/// The sheet for opening an **ad-hoc** SSH terminal or SFTP tab: the user types a
/// host, port and optional credentials and the app connects without a saved
/// profile. Key-based auth is tried first; a typed password is sent at the
/// prompt but never stored. Create a profile for anything you connect to often.
struct RemoteConnectionView: View {
    @ObservedObject var model: RemoteConnectionModel
    @EnvironmentObject var sessions: TerminalSessionManager

    @FocusState private var hostFocused: Bool

    private var trimmedHost: String { model.host.trimmingCharacters(in: .whitespaces) }
    private var parsedPort: Int? {
        let p = Int(model.port.trimmingCharacters(in: .whitespaces))
        return (p.map { $0 > 0 && $0 <= 65535 } ?? false) ? p : nil
    }
    private var canConnect: Bool { !trimmedHost.isEmpty && parsedPort != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            form
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            buttons
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { hostFocused = true }
    }

    private var header: some View {
        DialogHeader(icon: model.kind.symbol,
                     title: model.kind.title,
                     subtitle: model.kind.blurb,
                     helpArticleID: model.kind == .sftp ? "sftp" : "tunnels")
    }

    private var form: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text("Host").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("hostname or IP address", text: $model.host)
                        .textFieldStyle(.roundedBorder)
                        .focused($hostFocused)
                    ZeroTierPickerButton { model.host = $0 }
                }
            }
            GridRow {
                Text("Port").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                TextField("22", text: $model.port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .onChange(of: model.port) { newValue in
                        let digits = newValue.filter(\.isNumber)
                        if digits != newValue { model.port = digits }
                    }
                    .gridColumnAlignment(.leading)
            }
            GridRow {
                Text("Username").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                TextField("optional", text: $model.username)
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("Password").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                SecureField("optional", text: $model.password)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { model.isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button {
                connect()
            } label: {
                Label("Connect", systemImage: "bolt.horizontal.circle")
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canConnect)
        }
    }

    private var hint: String {
        "Connects without a saved profile. Your SSH keys are tried first; a typed "
        + "password is sent at the prompt but isn’t saved. For tunnels, a custom key, "
        + "a jump host or anything you use often, create a profile instead."
    }

    private func connect() {
        guard let port = parsedPort else { return }
        switch model.kind {
        case .ssh:
            sessions.openAdHocSSH(host: trimmedHost, port: port,
                                  username: model.username, password: model.password)
        case .sftp:
            sessions.openAdHocSFTP(host: trimmedHost, port: port,
                                   username: model.username, password: model.password)
        }
        model.isPresented = false
    }
}
