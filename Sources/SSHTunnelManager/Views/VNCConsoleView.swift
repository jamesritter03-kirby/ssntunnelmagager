import SwiftUI
import AppKit

/// The tab UI for a `.vnc` session. There are two shapes:
///
/// - **Tunneled** (opened from a profile): a `VNCClient` runs `ssh -N -L …` and
///   the embedded viewer connects to the local end of that tunnel. The console
///   reports the tunnel state and offers the raw `ssh` log.
/// - **Direct** (ad-hoc “New VNC Connection”): there's no SSH tunnel; the
///   embedded viewer connects straight to the typed `host:port`.
///
/// Both shapes render the remote desktop **inside the tab** (via
/// `EmbeddedVNCViewer` → RoyalVNCKit), with macOS Screen Sharing.app as a
/// one-click fallback.
struct VNCConsoleView: View {
    @ObservedObject var session: TerminalSession

    /// Non-nil only for a tunneled (profile/SSH) VNC tab.
    private let tunnelClient: VNCClient?
    /// The owning profile, if any — enables the File Transfer (SFTP) menu.
    private let profile: SSHProfile?

    init(session: TerminalSession) {
        _session = ObservedObject(initialValue: session)
        self.tunnelClient = session.vncClient
        self.profile = session.profileID.flatMap { id in
            ProfileStore.shared.profiles.first { $0.id == id }
        }
    }

    var body: some View {
        Group {
            // The viewer is owned by the long-lived `TerminalSession`, not this
            // view, so the live VNC connection (and its remembered credential)
            // survives workspace switches and tab re-mounts instead of
            // reconnecting — and re-prompting for the password — every time.
            if let viewer = session.embeddedVNCViewer {
                if let client = tunnelClient {
                    TunneledVNCConsole(session: session, client: client, viewer: viewer, profile: profile)
                } else {
                    DirectVNCConsole(session: session, viewer: viewer)
                }
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Tunneled (profile / SSH) console

private struct TunneledVNCConsole: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var client: VNCClient
    @ObservedObject var viewer: EmbeddedVNCViewer
    let profile: SSHProfile?

    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
        }
        .sheet(isPresented: $showLog) { logSheet }
        .onAppear { startViewerIfReady() }
        .onChange(of: client.phase) { _ in
            if client.phase == .connected {
                startViewerIfReady()
            } else {
                viewer.disconnect()
            }
        }
    }

    /// Connect the embedded viewer once the SSH tunnel is listening. A short
    /// delay lets the local `ssh -L` listener finish coming up before we dial it.
    private func startViewerIfReady() {
        guard client.phase == .connected else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            viewer.connect()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch client.phase {
        case .connecting, .idle:
            connectingScreen
        case .connected:
            VNCDesktopView(viewer: viewer, targetLabel: remoteTargetText,
                           profile: profile,
                           connectingText: "Connecting to the remote desktop…",
                           onShowLog: { showLog = true },
                           onDisconnect: { session.disconnect() })
        case .failed(let message):
            statusScreen(icon: "exclamationmark.triangle.fill", tint: .orange,
                         title: "Couldn’t open the tunnel", message: message)
        case .ended:
            statusScreen(icon: "bolt.horizontal.circle.fill", tint: .secondary,
                         title: "Disconnected",
                         message: "The VNC tunnel was closed. Reconnect to start screen sharing again.")
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

    private func statusScreen(icon: String, tint: Color, title: String,
                              message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 42)).foregroundStyle(tint)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 12) {
                Button { session.restart() } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                Button("Show Log") { showLog = true }
            }
        }
        .padding()
    }

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
                Button { viewer.openExternal() } label: {
                    Label("Screen Sharing", systemImage: "macwindow")
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

    private var remoteTargetText: String { "\(client.remoteHost):\(client.remotePort)" }

    private var statusColor: Color {
        switch client.phase {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .failed:       return .red
        case .ended, .idle: return .secondary
        }
    }
}

// MARK: - Direct (ad-hoc) console

private struct DirectVNCConsole: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var viewer: EmbeddedVNCViewer

    var body: some View {
        VStack(spacing: 0) {
            VNCDesktopView(viewer: viewer, targetLabel: targetText,
                           profile: nil,
                           connectingText: "Connecting to \(targetText)…",
                           onShowLog: nil,
                           onDisconnect: { viewer.disconnect() })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { viewer.connect() }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(isFailed ? Color.red : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if case .connected = viewer.status {
                Button { viewer.openExternal() } label: {
                    Label("Screen Sharing", systemImage: "macwindow")
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var targetText: String {
        "\(session.serviceHost):\(session.servicePort ?? VNCCommandBuilder.defaultRemotePort)"
    }

    private var isFailed: Bool { if case .failed = viewer.status { return true }; return false }

    private var statusText: String {
        switch viewer.status {
        case .idle:           return "Idle"
        case .connecting:     return "Connecting…"
        case .authenticating: return "Authenticating…"
        case .connected:      return "Connected · \(targetText)"
        case .failed(let m):  return m
        }
    }

    private var statusColor: Color {
        switch viewer.status {
        case .connected:                    return .green
        case .connecting, .authenticating:  return .yellow
        case .failed:                       return .red
        case .idle:                         return .secondary
        }
    }
}

// MARK: - Shared live-desktop view

/// The embedded remote desktop with its toolbar, reused by both consoles. Shows
/// the framebuffer when connected, an error with retry on failure, or a spinner
/// while connecting/authenticating.
private struct VNCDesktopView: View {
    @EnvironmentObject var sessions: TerminalSessionManager
    @ObservedObject var viewer: EmbeddedVNCViewer
    let targetLabel: String
    /// The owning profile, if any — enables the File Transfer (SFTP) menu. A
    /// direct (ad-hoc) VNC tab has no SSH connection, so it's `nil` there.
    let profile: SSHProfile?
    let connectingText: String
    /// `nil` hides the “show log” button (direct connections have no ssh log).
    let onShowLog: (() -> Void)?
    let onDisconnect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                Color.black
                desktopBody
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var desktopBody: some View {
        switch viewer.status {
        case .connected:
            VNCFramebufferHostView(framebufferView: viewer.framebufferView,
                                   nativeSize: viewer.framebufferSize,
                                   isScaling: viewer.isScalingEnabled)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36)).foregroundStyle(.orange)
                Text("Couldn’t show the remote desktop")
                    .font(.headline).foregroundStyle(.white)
                Text(message)
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
                HStack(spacing: 12) {
                    Button { viewer.connect() } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { viewer.openExternal() } label: {
                        Label("Open in Screen Sharing", systemImage: "macwindow")
                    }
                }
            }
            .padding()
        case .idle, .connecting, .authenticating:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large).tint(.white)
                Text(viewer.status == .authenticating ? "Authenticating…" : connectingText)
                    .foregroundStyle(.white.opacity(0.85))
                Button("Open in Screen Sharing") { viewer.openExternal() }
                    .buttonStyle(.link)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "display").foregroundStyle(.secondary)
            Text(targetLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let profile, !profile.isLocal {
                Menu {
                    Button {
                        sessions.revealOrOpenSFTP(profile: profile)
                    } label: {
                        Label("Open SFTP Browser", systemImage: "folder")
                    }
                    Button {
                        pickAndUpload(profile)
                    } label: {
                        Label("Upload Files…", systemImage: "arrow.up.doc")
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Transfer files to/from this server (SFTP)")
            }
            Button { viewer.setScaling(!viewer.isScalingEnabled) } label: {
                Image(systemName: viewer.isScalingEnabled
                      ? "arrow.up.left.and.arrow.down.right"
                      : "arrow.down.forward.and.arrow.up.backward")
            }
            .help(viewer.isScalingEnabled ? "Show actual size" : "Scale to fit window")
            .disabled(viewer.status != .connected)

            Button { viewer.openExternal() } label: {
                Image(systemName: "macwindow")
            }
            .help("Open in macOS Screen Sharing")

            if let onShowLog {
                Button { onShowLog() } label: {
                    Image(systemName: "doc.plaintext")
                }
                .help("Show the raw ssh log")
            }

            Button(role: .destructive) { onDisconnect() } label: {
                Image(systemName: "bolt.horizontal.circle")
            }
            .help("Disconnect")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    /// Pick local files/folders and upload them to the server over SFTP.
    private func pickAndUpload(_ profile: SSHProfile) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files or folders to upload to \(profile.name)"
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            sessions.uploadViaSFTP(profile: profile, urls: panel.urls)
        }
    }
}
