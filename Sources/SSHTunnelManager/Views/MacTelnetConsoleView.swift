import SwiftUI
import AppKit
import SwiftTerm

/// A WinBox-style MAC-Telnet console for a device discovered on the LAN. Shows a
/// small login form, then an interactive terminal driven over MAC-Telnet (UDP
/// broadcast) — so a flattened switch with no IP address can still be configured.
struct MacTelnetConsoleView: View {
    let device: DiscoveredRouter
    @Environment(\.dismiss) private var dismiss

    @State private var username = "admin"
    @State private var password = ""
    @State private var started = false

    var body: some View {
        VStack(spacing: 0) {
            if started {
                MacTelnetTerminal(device: device, username: username, password: password)
                    .frame(minWidth: 640, minHeight: 400)
            } else {
                loginForm
            }
        }
        .frame(minWidth: 480, minHeight: started ? 440 : 220)
    }

    private var loginForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "cable.connector")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect via MAC")
                        .font(.headline)
                    Text("\(device.displayName) · \(device.macAddress)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Form {
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
            }
            .formStyle(.grouped)

            Text("Uses MikroTik MAC-Telnet over UDP broadcast — works even when the device has no IP address, as long as it's on the same network segment and MAC-Telnet is enabled on its interface.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { started = true }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }
}

/// Hosts a SwiftTerm `TerminalView` wired to a `MacTelnetClient`.
struct MacTelnetTerminal: NSViewRepresentable {
    let device: DiscoveredRouter
    let username: String
    let password: String

    func makeCoordinator() -> Coordinator {
        Coordinator(device: device, username: username, password: password)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.terminalDelegate = context.coordinator
        TerminalTheme.default.apply(to: view)
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private let client: MacTelnetClient
        private weak var view: TerminalView?

        init(device: DiscoveredRouter, username: String, password: String) {
            client = MacTelnetClient(macAddress: device.macAddress,
                                     username: username,
                                     password: password,
                                     targetIP: device.ipv4)
            super.init()
            client.onOutput = { [weak self] bytes in
                DispatchQueue.main.async { self?.view?.feed(byteArray: bytes[...]) }
            }
        }

        func attach(_ view: TerminalView) {
            self.view = view
            let term = view.getTerminal()
            client.start(cols: UInt16(term.cols), rows: UInt16(term.rows))
        }

        func stop() { client.stop() }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            client.send(Array(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            client.resize(cols: UInt16(max(1, newCols)), rows: UInt16(max(1, newRows)))
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            }
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
