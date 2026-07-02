import SwiftUI

/// Drives the "edit connection" sheet used to re‑point a live service tab at new
/// connection details. Unlike the "new connection" sheets, this one starts from
/// an existing tab's current host / port / credentials and, on save, reconnects
/// that tab in place (see `TerminalSessionManager.reconnectSession`).
///
/// A singleton so the tab's right‑click menu can trigger it while the main window
/// presents it. Mirrors `ServiceConnectionModel` / `VNCConnectionModel`.
final class EditConnectionModel: ObservableObject {
    static let shared = EditConnectionModel()
    private init() {}

    @Published var isPresented = false
    /// The tab being edited.
    @Published var sessionID: UUID?
    @Published var kind: TerminalSession.Kind = .mqtt
    @Published var host = ""
    @Published var port = ""
    @Published var username = ""
    @Published var password = ""

    /// Open the sheet pre‑filled from a tab's current connection details.
    func present(for session: TerminalSession) {
        sessionID = session.id
        kind = session.kind
        // Profile‑backed SFTP tabs don't carry `service*` fields (their details
        // live in the profile and are baked into the sftp command), so read those
        // back from the profile. Everything else keeps its details on the session.
        if session.kind == .sftp, let pid = session.profileID,
           let profile = ProfileStore.shared.profiles.first(where: { $0.id == pid }) {
            host = profile.host
            port = profile.port
            username = profile.username
            password = session.presetPassword ?? ""
        } else {
            host = session.serviceHost
            port = session.servicePort.map(String.init) ?? (session.kind == .sftp ? "22" : "")
            username = session.serviceUsername
            password = session.kind == .sftp
                ? (session.presetPassword ?? "")
                : session.servicePassword
        }
        isPresented = true
    }

    var title: String {
        switch kind {
        case .mqtt:  return "MQTT"
        case .redis: return "Redis"
        case .vnc:   return "VNC"
        case .sftp:  return "SFTP"
        default:     return "Connection"
        }
    }

    var symbol: String {
        switch kind {
        case .mqtt:  return "antenna.radiowaves.left.and.right"
        case .redis: return "cylinder.split.1x2"
        case .vnc:   return "display"
        case .sftp:  return "arrow.up.arrow.down"
        default:     return "network"
        }
    }
}

/// The sheet for **changing a service tab's connection details** — host, port and
/// optional credentials — then reconnecting that tab in place. Reachable from the
/// right‑click menu of an MQTT, Redis, VNC (direct) or SFTP tab.
struct EditConnectionView: View {
    @ObservedObject var model: EditConnectionModel
    @EnvironmentObject var sessions: TerminalSessionManager

    @FocusState private var hostFocused: Bool

    private var trimmedHost: String { model.host.trimmingCharacters(in: .whitespaces) }
    private var parsedPort: Int? {
        let p = Int(model.port.trimmingCharacters(in: .whitespaces))
        return (p.map { $0 > 0 && $0 <= 65535 } ?? false) ? p : nil
    }
    private var canReconnect: Bool { !trimmedHost.isEmpty && parsedPort != nil }

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
        DialogHeader(icon: model.symbol,
                     title: "Edit \(model.title) Connection",
                     subtitle: "Change where this tab connects, then reconnect.")
    }

    private var form: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text("Host").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("127.0.0.1", text: $model.host)
                        .textFieldStyle(.roundedBorder)
                        .focused($hostFocused)
                    ZeroTierPickerButton { model.host = $0 }
                }
            }
            GridRow {
                Text("Port").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                TextField("", text: $model.port)
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
                reconnect()
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canReconnect)
        }
    }

    private var hint: String {
        switch model.kind {
        case .redis:
            return "Reconnects this Redis tab to the new details. Credentials are sent with AUTH and aren’t saved."
        case .mqtt:
            return "Reconnects this MQTT tab to the new details. Credentials are sent in the MQTT CONNECT packet and aren’t saved."
        case .vnc:
            return "Reconnects this VNC tab directly to the new details. Display options (scaling, colour depth, view‑only) are kept."
        case .sftp:
            return "Reopens this SFTP tab against the new details. A typed password is used for this session only and isn’t saved."
        default:
            return "Reconnects this tab to the new details."
        }
    }

    private func reconnect() {
        guard let id = model.sessionID, let port = parsedPort else { return }
        sessions.reconnectSession(id,
                                  host: trimmedHost,
                                  port: port,
                                  username: model.username,
                                  password: model.password)
        model.isPresented = false
    }
}
