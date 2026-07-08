import SwiftUI

/// Presents the "add a live port forward" sheet for a running tunnel.
final class AddForwardModel: ObservableObject {
    static let shared = AddForwardModel()
    private init() {}

    @Published var isPresented = false
    /// The session the forward will be added to.
    weak var session: TerminalSession?

    func present(for session: TerminalSession) {
        self.session = session
        isPresented = true
    }
}

/// A small form to add a port forward to a **live** SSH tunnel (via
/// `ssh -O forward`), optionally saving it to the profile too.
struct AddForwardView: View {
    @ObservedObject var model: AddForwardModel
    @EnvironmentObject var sessions: TerminalSessionManager
    @Environment(\.dismiss) private var dismiss

    @State private var type: ForwardType = .local
    @State private var bindAddress = ""
    @State private var listenPort = ""
    @State private var targetHost = "localhost"
    @State private var targetPort = ""
    @State private var persist = true

    private var canAdd: Bool {
        guard !listenPort.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if type == .dynamic { return true }
        return !targetPort.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Port Forward").font(.headline)
                    Text("Adds it to the live connection immediately")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            Divider()

            Form {
                Picker("Type", selection: $type) {
                    ForEach(ForwardType.allCases) { Text($0.title).tag($0) }
                }
                Text(type.explanation)
                    .font(.caption).foregroundStyle(.secondary)

                LabeledContent("Listen port") {
                    TextField(type == .remote ? "server port" : "local port", text: $listenPort)
                        .frame(maxWidth: 120)
                }
                if type != .dynamic {
                    LabeledContent("Target host") {
                        TextField("localhost", text: $targetHost)
                    }
                    LabeledContent("Target port") {
                        TextField("port", text: $targetPort)
                            .frame(maxWidth: 120)
                    }
                }
                LabeledContent("Bind address") {
                    TextField("optional (e.g. 127.0.0.1)", text: $bindAddress)
                }
                Toggle("Also save to the profile", isOn: $persist)
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
            .padding(14)
        }
        .frame(width: 460)
    }

    private func add() {
        guard let session = model.session else { dismiss(); return }
        var forward = PortForward()
        forward.type = type
        forward.bindAddress = bindAddress.trimmingCharacters(in: .whitespaces)
        forward.listenPort = listenPort.trimmingCharacters(in: .whitespaces)
        forward.targetHost = targetHost.trimmingCharacters(in: .whitespaces)
        forward.targetPort = targetPort.trimmingCharacters(in: .whitespaces)
        sessions.addLiveForward(forward, to: session, persist: persist)
        dismiss()
    }
}
