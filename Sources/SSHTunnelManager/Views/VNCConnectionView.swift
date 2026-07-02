import SwiftUI

/// Drives the "new VNC connection" setup sheet. A singleton so the tab-bar **+**
/// menu, the **New** menu and the welcome screen can all trigger it while the
/// main window presents it. Mirrors `ServiceConnectionModel`.
final class VNCConnectionModel: ObservableObject {
    static let shared = VNCConnectionModel()
    private init() {}

    @Published var isPresented = false
    @Published var host = ""
    @Published var port = ""
    @Published var username = ""
    @Published var password = ""
    /// Scale the remote screen to fit the tab (vs. show it 1:1 / actual size).
    @Published var scaling = true
    /// Look, don’t touch — suppress all mouse/keyboard input to the remote.
    @Published var viewOnly = false
    /// Remote-desktop colour fidelity.
    @Published var colorDepth: EmbeddedVNCViewer.ColorDepthOption = .trueColor

    /// Present the sheet pre-filled with the default VNC port.
    func present() {
        host = ""
        port = String(VNCCommandBuilder.defaultRemotePort)   // 5900
        username = ""
        password = ""
        scaling = true
        viewOnly = false
        colorDepth = .trueColor
        isPresented = true
    }
}

/// The sheet for opening an **ad-hoc** VNC tab: the user types a host, port and
/// optional credentials, and the app opens an embedded VNC tab that connects
/// **directly** to that server (no SSH tunnel / profile required). For an
/// encrypted session, open VNC from a profile instead — that tunnels over SSH.
struct VNCConnectionView: View {
    @ObservedObject var model: VNCConnectionModel
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
        DialogHeader(icon: "display",
                     title: "New VNC Connection",
                     subtitle: "View a computer’s screen over VNC.",
                     helpArticleID: "vnc")
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
                TextField("\(VNCCommandBuilder.defaultRemotePort)", text: $model.port)
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
            GridRow {
                Text("Display").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                Picker("", selection: $model.scaling) {
                    Text("Scale to Fit").tag(true)
                    Text("Actual Size").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .gridColumnAlignment(.leading)
            }
            GridRow {
                Text("Colors").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                Picker("", selection: $model.colorDepth) {
                    ForEach(EmbeddedVNCViewer.ColorDepthOption.allCases) { depth in
                        Text(depth.title).tag(depth)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .gridColumnAlignment(.leading)
            }
            GridRow {
                Text("Input").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                Toggle("View only (don’t send mouse or keyboard)", isOn: $model.viewOnly)
                    .toggleStyle(.checkbox)
                    .gridColumnAlignment(.leading)
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
        "Connects **directly** to the VNC server — this is not tunneled. For an encrypted "
        + "connection over SSH, open VNC from a profile instead. The username (for Apple Remote "
        + "Desktop) and password are optional and aren’t saved."
    }

    private func connect() {
        guard let port = parsedPort else { return }
        sessions.openAdHocVNC(host: trimmedHost,
                              port: port,
                              username: model.username,
                              password: model.password,
                              scaling: model.scaling,
                              viewOnly: model.viewOnly,
                              colorDepth: model.colorDepth)
        model.isPresented = false
    }
}
