import SwiftUI

/// Drives the "new MQTT / Redis connection" setup sheet. A singleton so the
/// tab-bar **+** menu, the **New** menu and the welcome screen can all trigger
/// it while the main window presents it.
final class ServiceConnectionModel: ObservableObject {
    static let shared = ServiceConnectionModel()
    private init() {}

    @Published var isPresented = false
    @Published var category: ForwardCategory = .mqtt
    @Published var host = "127.0.0.1"
    @Published var port = ""
    @Published var username = ""
    @Published var password = ""

    /// Present the sheet pre-filled for a service category with its default port.
    func present(_ category: ForwardCategory) {
        self.category = category
        host = "127.0.0.1"
        port = String(category.defaultPort)
        username = ""
        password = ""
        isPresented = true
    }
}

/// The sheet for opening an **ad-hoc** MQTT or Redis tab: the user types a host,
/// port and optional credentials, and the app opens a native client tab that
/// connects directly (no SSH tunnel / profile required).
struct ServiceConnectionView: View {
    @ObservedObject var model: ServiceConnectionModel
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
            servicePicker
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
        DialogHeader(icon: model.category.symbol,
                     title: "New \(model.category.title) Connection",
                     subtitle: "Connect directly to a \(model.category.title) server.",
                     helpArticleID: "services")
    }

    private var servicePicker: some View {
        Picker("Service", selection: serviceBinding) {
            Text("MQTT").tag(ForwardCategory.mqtt)
            Text("Redis").tag(ForwardCategory.redis)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// Switching the service swaps in its default port — but only when the field
    /// still holds the previous service's default, so a custom port is kept.
    private var serviceBinding: Binding<ForwardCategory> {
        Binding(
            get: { model.category },
            set: { newValue in
                if model.port.trimmingCharacters(in: .whitespaces) == String(model.category.defaultPort) {
                    model.port = String(newValue.defaultPort)
                }
                model.category = newValue
            }
        )
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
                TextField("\(model.category.defaultPort)", text: $model.port)
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
        switch model.category {
        case .redis:
            return "Opens a Redis browser tab. Credentials are sent with AUTH over the connection and aren’t saved."
        default:
            return "Opens an MQTT Explorer tab. Credentials are sent in the MQTT CONNECT packet and aren’t saved."
        }
    }

    private func connect() {
        guard let port = parsedPort else { return }
        sessions.openAdHocService(category: model.category,
                                  host: trimmedHost,
                                  port: port,
                                  username: model.username,
                                  password: model.password)
        model.isPresented = false
    }
}
