import SwiftUI
import AppKit

/// The tab UI for a `.vnc` session. The remote desktop is shown by macOS's
/// **Screen Sharing.app** (launched automatically once the SSH tunnel is up), so
/// this view is a compact status/control console: it reports the tunnel state,
/// shows the forwarded address, and lets the user re-open the viewer, reconnect,
/// or inspect the raw `ssh` log.
struct VNCConsoleView: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var client: VNCClient

    @State private var showLog = false

    init(session: TerminalSession) {
        _session = ObservedObject(initialValue: session)
        _client = ObservedObject(initialValue: session.vncClient ?? VNCClient(
            executable: VNCCommandBuilder.sshPath, args: [], profileID: nil,
            autofillPassword: false, requireAuthForPassword: false))
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showLog) { logSheet }
    }

    // MARK: - State screens

    @ViewBuilder
    private var content: some View {
        switch client.phase {
        case .connecting, .idle:
            connectingScreen
        case .connected:
            connectedScreen
        case .failed(let message):
            statusScreen(icon: "exclamationmark.triangle.fill", tint: .orange,
                         title: "Couldn’t open the tunnel", message: message,
                         showReconnect: true)
        case .ended:
            statusScreen(icon: "bolt.horizontal.circle.fill", tint: .secondary,
                         title: "Disconnected",
                         message: "The VNC tunnel was closed. Reconnect to start screen sharing again.",
                         showReconnect: true)
        }
    }

    private var connectingScreen: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(client.statusMessage.isEmpty ? "Opening secure tunnel…" : client.statusMessage)
                .foregroundStyle(.secondary)
            Text("Connecting over SSH to \(remoteTargetText)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Show Log") { showLog = true }
                .buttonStyle(.link)
        }
        .padding()
    }

    private var connectedScreen: some View {
        VStack(spacing: 16) {
            Image(systemName: "display").font(.system(size: 46)).foregroundStyle(.tint)
            Text("Screen sharing is live").font(.title3.weight(.semibold))
            VStack(spacing: 4) {
                Text("macOS Screen Sharing is connected through an encrypted SSH tunnel.")
                Text("Remote \(remoteTargetText)  ·  local 127.0.0.1:\(client.localPort)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)

            HStack(spacing: 12) {
                Button { client.openViewer() } label: {
                    Label("Open Screen Sharing", systemImage: "display")
                }
                .buttonStyle(.borderedProminent)
                Button(role: .destructive) { session.disconnect() } label: {
                    Label("Disconnect", systemImage: "bolt.horizontal.circle")
                }
            }
            Text("If the viewer didn’t appear, click **Open Screen Sharing**.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func statusScreen(icon: String, tint: Color, title: String,
                              message: String, showReconnect: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 42)).foregroundStyle(tint)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 12) {
                if showReconnect {
                    Button { session.restart() } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Show Log") { showLog = true }
            }
        }
        .padding()
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(client.statusMessage.isEmpty ? "Idle" : client.statusMessage)
                .font(.caption)
                .foregroundStyle(client.errorMessage != nil ? Color.red : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if client.isConnected {
                Button { client.openViewer() } label: {
                    Label("Open Viewer", systemImage: "display")
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Divider().frame(height: 14)
            Button { showLog = true } label: { Image(systemName: "doc.plaintext") }
                .buttonStyle(.borderless)
                .help("Show the raw ssh log")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var logSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("VNC Tunnel Log").font(.headline)
                Spacer()
                Button("Done") { showLog = false }
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(client.transcript.isEmpty ? "No output yet." : client.transcript)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(width: 560, height: 420)
    }

    // MARK: - Helpers

    private var remoteTargetText: String {
        "\(client.remoteHost):\(client.remotePort)"
    }

    private var statusColor: Color {
        switch client.phase {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .failed:       return .red
        case .ended, .idle: return .secondary
        }
    }
}
