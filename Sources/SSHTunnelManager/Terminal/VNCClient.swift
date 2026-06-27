import Foundation
import AppKit
import SwiftTerm

/// Drives a headless `ssh -N` VNC tunnel (PTY-backed via SwiftTerm's
/// `LocalProcess`) and launches macOS Screen Sharing once the local port-forward
/// is listening. Authentication (password autofill / host-key confirmation)
/// reuses the same scraping approach as `SFTPClient` / the terminal sessions.
///
/// The remote desktop itself is shown by Apple's **Screen Sharing.app** (there's
/// no embeddable VNC view on macOS), so this object is the "engine" behind a
/// small status/control console (`VNCConsoleView`) rather than a rendered screen.
final class VNCClient: NSObject, ObservableObject, LocalProcessDelegate {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
        case ended
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript: String = ""
    @Published var statusMessage: String = ""
    @Published var errorMessage: String?

    /// The local loopback port this Mac listens on; Screen Sharing connects here.
    let localPort: Int
    /// The remote target the tunnel forwards to (as seen from the server).
    let remoteHost: String
    let remotePort: Int

    /// The owning session mirrors this to drive the tab's running indicator.
    var onRunningChanged: ((Bool) -> Void)?

    var isConnected: Bool { phase == .connected }
    var isConnecting: Bool { phase == .connecting }

    /// The `vnc://` URL Screen Sharing opens (the local end of the tunnel).
    var viewerURL: URL? { URL(string: "vnc://127.0.0.1:\(localPort)") }

    private let executable: String
    private let args: [String]
    private let profileID: UUID?
    private let autofillPassword: Bool
    private let requireAuthForPassword: Bool

    private var process: LocalProcess!
    private var buffer = ""
    private var didAutofillPassword = false
    private var handlingAuthPrompt = false
    private var didMarkConnected = false

    init(executable: String, args: [String], profileID: UUID?,
         autofillPassword: Bool, requireAuthForPassword: Bool) {
        self.executable = executable
        self.args = args
        self.profileID = profileID
        self.autofillPassword = autofillPassword
        self.requireAuthForPassword = requireAuthForPassword
        let forward = VNCCommandBuilder.parseForward(in: args)
        self.localPort = forward?.localPort ?? 0
        self.remoteHost = forward?.remoteHost ?? VNCCommandBuilder.defaultRemoteHost
        self.remotePort = forward?.remotePort ?? VNCCommandBuilder.defaultRemotePort
        super.init()
        process = LocalProcess(delegate: self, dispatchQueue: .main)
    }

    // MARK: - Lifecycle

    func start() {
        guard phase != .connecting, phase != .connected else { return }
        buffer = ""
        didAutofillPassword = false
        handlingAuthPrompt = false
        didMarkConnected = false
        errorMessage = nil
        phase = .connecting
        statusMessage = "Opening secure tunnel…"
        onRunningChanged?(true)

        // Force a dumb, very wide terminal so ssh's prompts/`-v` diagnostics don't
        // get wrapped or decorated with cursor escapes.
        var env = TerminalSession.environment().filter { !$0.hasPrefix("TERM=") }
        env.append("TERM=dumb")
        process.startProcess(executable: executable, args: args, environment: env, execName: nil)
    }

    /// Re-open Screen Sharing for the live tunnel (e.g. the user closed the window).
    func openViewer() {
        guard let url = viewerURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Gracefully end the session (closes the tunnel).
    func disconnect() {
        guard phase == .connecting || phase == .connected else { return }
        let pid = process.shellPid
        if process.running, pid > 0 { kill(pid, SIGHUP) }
    }

    /// Tear down any existing process and connect again.
    func reconnect() {
        if process.running, process.shellPid > 0 { kill(process.shellPid, SIGHUP) }
        process = LocalProcess(delegate: self, dispatchQueue: .main)
        phase = .idle
        start()
    }

    // MARK: - LocalProcessDelegate

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        if case .failed = phase {} else {
            phase = .ended
            statusMessage = "Tunnel closed"
        }
        onRunningChanged?(false)
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        let text = SFTPClient.stripANSI(String(decoding: slice, as: UTF8.self))
        transcript += text
        if transcript.count > 60_000 { transcript = String(transcript.suffix(40_000)) }
        guard phase == .connecting else { return }
        buffer += text
        handleConnecting()
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: 24, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0)
    }

    // MARK: - Connect / auth handling

    private func handleConnecting() {
        guard !handlingAuthPrompt else { return }
        if let line = SFTPClient.lastNonEmptyLine(buffer) {
            if SFTPClient.looksLikeSecretPrompt(line) { handleSecretPrompt(); return }
        }
        if SFTPClient.looksLikeHostKeyPrompt(buffer) { handleHostKeyPrompt(); return }
        if let failure = SFTPClient.failureMessage(in: buffer) { fail(failure); return }
        // The local listener is bound once ssh logs this (it then accepts
        // connections), so it's safe for the in-app viewer to connect.
        if buffer.contains("Local forwarding listening on")
            || buffer.contains("Entering interactive session") {
            markConnected()
        }
    }

    private func markConnected() {
        guard !didMarkConnected else { return }
        didMarkConnected = true
        buffer = ""
        phase = .connected
        statusMessage = "Tunnel ready · 127.0.0.1:\(localPort)"
        // No external app is launched here any more: `VNCConsoleView` watches for
        // `.connected` and connects the embedded VNC viewer to the local port.
        // `openViewer()` remains available as a manual "Open in Screen Sharing"
        // fallback.
    }

    private func handleSecretPrompt() {
        handlingAuthPrompt = true
        buffer = ""
        if !didAutofillPassword, autofillPassword, let pid = profileID {
            didAutofillPassword = true
            KeychainStore.shared.password(for: pid, requireAuth: requireAuthForPassword,
                                          reason: "Use the saved password for the VNC tunnel") { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let pw): self.sendRaw(pw + "\n"); self.handlingAuthPrompt = false
                    case .failure:         self.askUserForPassword()
                    }
                }
            }
        } else {
            askUserForPassword()
        }
    }

    private func askUserForPassword() {
        let alert = NSAlert()
        alert.messageText = "Password required"
        alert.informativeText = "Enter the password for this SSH connection."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            sendRaw(field.stringValue + "\n")
            handlingAuthPrompt = false
        } else {
            disconnect()
        }
    }

    private func handleHostKeyPrompt() {
        handlingAuthPrompt = true
        let detail = buffer
        buffer = ""
        let alert = NSAlert()
        alert.messageText = "Verify host key"
        alert.informativeText = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            sendRaw("yes\n")
        } else {
            sendRaw("no\n")
            fail("Host key not accepted.")
        }
        handlingAuthPrompt = false
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        statusMessage = message
        errorMessage = message
        onRunningChanged?(false)
        if process.running, process.shellPid > 0 { kill(process.shellPid, SIGHUP) }
    }

    private func sendRaw(_ s: String) {
        let bytes = Array(s.utf8)
        process.send(data: bytes[...])
    }
}

