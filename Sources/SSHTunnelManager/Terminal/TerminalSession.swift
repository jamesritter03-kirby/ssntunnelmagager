import Foundation
import AppKit
import SwiftTerm

/// Tracks whether we're in the middle of a terminal escape sequence while
/// reconstructing a typed command line.
private enum LineEscapeState {
    case normal
    case esc
    case csi
}

/// Live reachability of a profile's forwarded local ports (the tunnel-health dot).
enum TunnelHealth: Equatable {
    case unknown    // not probed yet, or the session has no local forwards
    case healthy    // every forwarded local port accepts a connection
    case degraded   // at least one forwarded local port refused a connection
}

/// One terminal tab: owns a SwiftTerm process-backed view and tracks its lifecycle.
final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()

    enum Kind: String, Equatable, Codable {
        case localShell
        case ssh
        case sftp
        case vnc
        case web
        case mqtt
        case redis
        case finder
        case editor
        case spreadsheet
    }

    let kind: Kind
    @Published var title: String
    @Published var isRunning: Bool = true
    @Published var exitCode: Int32? = nil
    /// An optional user-chosen tint for this tab's chip (nil = default accent).
    /// Set from the tab's right-click "Tab Color" menu; persisted per tab.
    @Published var tabColor: TabColor? = nil
    /// Commands typed in this tab, oldest first. Re-runnable from the history menu.
    @Published private(set) var commandHistory: [String] = []
    /// Live reachability of this session's forwarded local ports (sidebar dot).
    @Published var tunnelHealth: TunnelHealth = .unknown
    /// Set when the user deliberately stopped this session (Disconnect / close /
    /// quit), so the manager's auto-reconnect doesn't treat it as a dropped link.
    var userInitiatedStop = false
    /// Toggled to force tab UI (chips / dock headers) to re-read `isPaused` when a
    /// web tab's paused state changes — the web model is a separate observable.
    @Published private var pausedTick = false
    /// Invoked with the raw bytes the user types, when broadcast-input is on, so
    /// the manager can mirror them to every other live terminal. Nil = no relay.
    var onUserTypedForBroadcast: ((ArraySlice<UInt8>) -> Void)?

    /// The command used to launch this session (for display / reconnect).
    let executable: String
    let args: [String]
    let commandPreview: String
    /// The profile this session was launched from (nil for a plain local shell).
    let profileID: UUID?
    /// The color theme applied to this terminal.
    private(set) var theme: TerminalTheme
    /// The terminal text size in points (live-adjustable with ⌘+ / ⌘−).
    @Published private(set) var fontSize: Double
    /// Whether a Keychain password should be typed at the password prompt.
    let autofillPassword: Bool
    /// Whether to require Touch ID / login password before using it.
    let requireAuthForPassword: Bool
    /// A password supplied up front (the ad-hoc “new connection” sheet) to type
    /// at the first password prompt, instead of reading one from the Keychain.
    /// Used for profile-free SSH / SFTP tabs; never persisted.
    let presetPassword: String?
    /// A profile whose saved Keychain password this tab may autofill even though
    /// the tab itself is profile-free. Set for ad-hoc ssh / sftp tabs rebuilt
    /// inside a **profile-launched workspace**, so they use the launching
    /// profile's saved password (Touch ID gated) instead of prompting for manual
    /// entry. `nil` for ordinary tabs.
    let autofillSourceProfileID: UUID?
    /// Whether Touch ID / login password is required before using that source
    /// profile's saved password.
    let autofillSourceRequireAuth: Bool
    /// For local-shell sessions: the folder the shell should start in (nil = default).
    let startDirectory: String?

    /// A command typed and run automatically once the shell is ready
    /// (`profile.runOnConnect`, or a per-tab override set from the tab menu).
    /// Nil / empty = nothing is auto-run.
    var runOnConnectCommand: String?
    /// Whether this session's output is being recorded to a log file.
    let sessionLoggingEnabled: Bool
    /// For profile-backed ssh tunnels: the ControlMaster socket path, so forwards
    /// can be added/removed live via `ssh -O forward`. Nil for other tabs.
    let controlSocketPath: String?

    let terminalView: HistoryTerminalView

    /// Intercepts ⌘‑clicked web links in the terminal so they open in an in‑app
    /// browser tab. Retained here because `terminalView.terminalDelegate` is weak.
    private var linkDelegate: TerminalLinkDelegate?

    /// For `.sftp` sessions: the headless driver behind the graphical browser.
    let sftpClient: SFTPClient?

    /// For `.sftp` sessions: mounts the remote filesystem locally via `sshfs`
    /// (FUSE) so it can be browsed in Finder. `nil` for non-sftp tabs.
    let sftpMounter: SFTPMounter?

    /// For `.vnc` sessions: the headless ssh-tunnel driver behind the console.
    let vncClient: VNCClient?

    /// For `.vnc` sessions: the embedded RoyalVNCKit viewer that renders the
    /// remote desktop. Owned by the **session** (not the SwiftUI view) so the
    /// live VNC connection — and its remembered credential — survives workspace
    /// switches and tab re-mounts instead of reconnecting (and re-prompting for
    /// the password) every time the tab leaves and re-enters the view hierarchy.
    let embeddedVNCViewer: EmbeddedVNCViewer?

    /// For `.web` sessions: the in-app browser tab's navigation model.
    let webModel: WebTabModel?

    /// For `.mqtt` sessions: the native MQTT broker client behind `MQTTExplorerView`.
    let mqttClient: MQTTClient?

    /// For `.redis` sessions: the native Redis client behind `RedisBrowserView`.
    let redisClient: RedisClient?

    /// For `.finder` sessions: the local file browser behind `FinderBrowserView`.
    let finderModel: LocalFileBrowser?

    /// For `.editor` sessions: the text document behind `TextEditorTabView`.
    let textEditorModel: TextEditorModel?

    /// For `.spreadsheet` sessions: the delimited-grid document behind
    /// `SpreadsheetTabView`.
    let spreadsheetModel: SpreadsheetModel?

    /// For `.mqtt` / `.redis` sessions: the local (forwarded) port the native
    /// client connects to, kept so the tab can be recreated on the next launch.
    let servicePort: Int?

    /// For native-client tabs that connect **directly** to a host (ad-hoc
    /// `.mqtt` / `.redis`, and direct `.vnc`): the target host, optional username
    /// and password. For a direct VNC tab these point the embedded viewer at the
    /// VNC server (no SSH tunnel / profile).
    let serviceHost: String
    let serviceUsername: String
    let servicePassword: String

    /// Extra environment variables merged into the child process's environment
    /// (e.g. `REDISCLI_AUTH` so a Redis password never appears in `args` / `ps`).
    private let extraEnvironment: [String: String]

    /// The SF Symbol used to represent this session in tabs, tiles and lists.
    var symbolName: String {
        // A profile's chosen icon wins for shell / ssh tabs; sftp and vnc keep
        // their distinctive type icons so the tab kind stays recognisable.
        if kind == .ssh || kind == .localShell,
           let pid = profileID,
           let profile = ProfileStore.shared.profiles.first(where: { $0.id == pid }),
           !profile.icon.trimmingCharacters(in: .whitespaces).isEmpty {
            return profile.icon
        }
        switch kind {
        case .localShell: return "terminal"
        case .ssh:        return "terminal"
        case .sftp:       return "arrow.up.arrow.down"
        case .vnc:        return "display"
        case .web:        return "globe"
        case .mqtt:       return "antenna.radiowaves.left.and.right"
        case .redis:      return "cylinder.split.1x2"
        case .finder:     return "folder"
        case .editor:     return "doc.text"
        case .spreadsheet: return "tablecells"
        }
    }

    /// Remote sessions (ssh / sftp / vnc) and the native service clients
    /// (mqtt / redis) are live connections — “Disconnect”; local shells are “Stop”.
    var isRemote: Bool {
        kind == .ssh || kind == .sftp || kind == .vnc || kind == .mqtt || kind == .redis
    }

    /// Whether the tab is currently paused by the user: a web tab whose page has
    /// been unloaded via Pause, or a connection / local process the user paused
    /// (stopped without the tab ending on its own). Drives the paused tab badge.
    var isPaused: Bool {
        if kind == .web { return webModel?.isPaused ?? false }
        if kind == .finder || kind == .editor || kind == .spreadsheet { return false }
        return userInitiatedStop && !isRunning
    }

    /// Whether a per-command history makes sense for this tab: the interactive
    /// shells. (The mqtt / redis tabs are graphical clients, not REPLs.)
    var supportsCommandHistory: Bool {
        kind == .ssh || kind == .localShell
    }

    /// Whether this tab exposes editable connection details (host / port /
    /// credentials) that can be changed and reconnected in place via the
    /// right‑click **Edit Connection…** action. True for the native service tabs
    /// (mqtt / redis) and sftp; for vnc only when it's a **direct** connection —
    /// a tunnelled VNC tab gets its endpoint from its profile.
    var canEditConnection: Bool {
        switch kind {
        case .mqtt, .redis, .sftp: return true
        case .vnc:                 return vncClient == nil
        default:                   return false
        }
    }

    /// Whether “Duplicate Tab” makes sense for this tab. Every kind can be copied
    /// except a **profile-backed ssh** tab: its tunnel binds fixed forwarded
    /// ports, so a second one couldn't bind them (and the app keeps one tab per
    /// profile anyway). An ad-hoc ssh tab — a plain interactive shell with no
    /// forwards — duplicates fine.
    var canDuplicate: Bool {
        switch kind {
        case .ssh: return profileID == nil
        default:   return true
        }
    }

    private var hasStarted = false

    // Command-line reconstruction state (see handleInput).
    private var lineBuffer: [UInt8] = []
    private var escapeState: LineEscapeState = .normal
    private var isInjecting = false
    private var secretPromptActive = false
    private var recentOutputTail = ""
    private let historyLimit = 300
    /// How many times we've auto-typed the saved password this connection. Capped
    /// (see `maxAutofillAttempts`) so a pre-auth banner that merely *mentions* a
    /// password — or a second authentication prompt (a bastion hop) — doesn't burn
    /// the one chance, while a genuinely wrong stored password still can't loop.
    private var autofillAttempts = 0
    private let maxAutofillAttempts = 2
    /// The saved password once it's been unlocked (Touch ID) this connection, held
    /// briefly so a second prompt can be answered without prompting for Touch ID
    /// again. Cleared on (re)start and a short while after it's cached.
    private var cachedAutofillSecret: String?
    /// Set when a PTY start was requested before the view was on screen; the
    /// pending start runs once `startIfPending()` sees the view attached.
    private var pendingStart = false

    /// Run-on-connect bookkeeping: the command still to fire, and whether it has
    /// already been scheduled/sent for this connection.
    private var runOnConnectFired = false
    /// Session-log file handle (opened lazily on start when logging is enabled).
    private var logHandle: FileHandle?
    /// The on-disk location of this session's transcript log, if logging.
    private(set) var sessionLogURL: URL?

    init(kind: Kind, title: String, executable: String, args: [String], commandPreview: String, profileID: UUID? = nil, theme: TerminalTheme = .default, fontSize: Double = TerminalFontMetrics.default, autofillPassword: Bool = false, requireAuthForPassword: Bool = true, autofillSourceProfileID: UUID? = nil, autofillSourceRequireAuth: Bool = true, startDirectory: String? = nil, editorBackupID: UUID? = nil, webURL: URL? = nil, webProxy: WebProxy? = nil, servicePort: Int? = nil, serviceHost: String = "127.0.0.1", serviceUsername: String = "", servicePassword: String = "", presetPassword: String? = nil, sftpMountCredentialID: UUID? = nil, extraEnvironment: [String: String] = [:], vncScaling: Bool = true, vncViewOnly: Bool = false, vncColorDepth: EmbeddedVNCViewer.ColorDepthOption = .trueColor, runOnConnectCommand: String? = nil, logSession: Bool = false, controlSocketPath: String? = nil) {
        self.kind = kind
        self.title = title
        self.executable = executable
        self.args = args
        self.commandPreview = commandPreview
        self.profileID = profileID
        self.theme = theme
        self.fontSize = TerminalFontMetrics.clamp(fontSize)
        self.autofillPassword = autofillPassword
        self.requireAuthForPassword = requireAuthForPassword
        self.autofillSourceProfileID = autofillSourceProfileID
        self.autofillSourceRequireAuth = autofillSourceRequireAuth
        self.startDirectory = startDirectory
        let trimmedRunOnConnect = runOnConnectCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.runOnConnectCommand = (trimmedRunOnConnect?.isEmpty == false) ? trimmedRunOnConnect : nil
        self.sessionLoggingEnabled = logSession && (kind == .ssh || kind == .localShell)
        self.controlSocketPath = controlSocketPath
        self.servicePort = servicePort
        self.serviceHost = serviceHost
        self.serviceUsername = serviceUsername
        self.servicePassword = servicePassword
        self.presetPassword = presetPassword
        self.extraEnvironment = extraEnvironment
        self.terminalView = HistoryTerminalView(frame: NSRect(x: 0, y: 0, width: 820, height: 480))
        if kind == .sftp {
            self.sftpClient = SFTPClient(executable: executable, args: args, profileID: profileID,
                                         autofillPassword: autofillPassword,
                                         requireAuthForPassword: requireAuthForPassword,
                                         presetPassword: presetPassword,
                                         autofillSourceProfileID: autofillSourceProfileID,
                                         autofillSourceRequireAuth: autofillSourceRequireAuth)
            // A profile-backed tab mounts via its profile. Any ad-hoc tab with a
            // captured host is mountable too: it uses that host / port / username,
            // with its typed password (in memory) or one persisted under
            // `sftpMountCredentialID` (a tab rebuilt from a workspace profile).
            if let profileID {
                self.sftpMounter = SFTPMounter(profileID: profileID)
            } else if !serviceHost.isEmpty {
                self.sftpMounter = SFTPMounter(adHocHost: serviceHost, port: servicePort ?? 22,
                                               username: serviceUsername,
                                               password: presetPassword,
                                               credentialID: sftpMountCredentialID)
            } else {
                self.sftpMounter = SFTPMounter(profileID: nil)
            }
        } else {
            self.sftpClient = nil
            self.sftpMounter = nil
        }
        // A profile/SSH-tunneled VNC tab carries `ssh -L` args and gets a
        // `VNCClient` to drive the tunnel. An ad-hoc *direct* VNC tab has no args
        // (it connects straight to `serviceHost:servicePort`), so it has no
        // tunnel client — `VNCConsoleView` points the embedded viewer at the host.
        if kind == .vnc, !args.isEmpty {
            self.vncClient = VNCClient(executable: executable, args: args, profileID: profileID,
                                       autofillPassword: autofillPassword,
                                       requireAuthForPassword: requireAuthForPassword)
        } else {
            self.vncClient = nil
        }
        // Build the embedded viewer up front so it lives as long as the session.
        if kind == .vnc {
            let vncProfile = profileID.flatMap { id in
                ProfileStore.shared.profiles.first { $0.id == id }
            }
            let vHost: String, vPort: Int, vPreset: String?, vLabel: String, vUser: String
            let vRequireBio: Bool
            if let client = self.vncClient {
                // Tunneled: dial the local end of the ssh forward.
                vHost = "127.0.0.1"
                vPort = client.localPort
                vPreset = nil
                vLabel = vncProfile?.name ?? "\(client.remoteHost):\(client.remotePort)"
                vUser = (vncProfile?.username).flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
                vRequireBio = vncProfile?.requireAuthForSavedPassword ?? false
            } else {
                // Direct (ad-hoc): dial the typed host:port.
                let p = servicePort ?? VNCCommandBuilder.defaultRemotePort
                vHost = serviceHost
                vPort = p
                vPreset = servicePassword.isEmpty ? nil : servicePassword
                vLabel = "\(serviceHost):\(p)"
                vUser = serviceUsername.isEmpty ? NSUserName() : serviceUsername
                vRequireBio = false
            }
            self.embeddedVNCViewer = EmbeddedVNCViewer(
                host: vHost, port: vPort, profileID: profileID,
                defaultUsername: vUser, serverLabel: vLabel,
                presetPassword: vPreset, requireBiometricAuth: vRequireBio,
                scaling: vncScaling, viewOnly: vncViewOnly, colorDepth: vncColorDepth)
        } else {
            self.embeddedVNCViewer = nil
        }
        if kind == .web {
            self.webModel = WebTabModel(initialURL: webURL, proxy: webProxy)
        } else {
            self.webModel = nil
        }
        if kind == .mqtt, let port = servicePort {
            self.mqttClient = MQTTClient(host: serviceHost, port: port,
                                         username: serviceUsername, password: servicePassword)
        } else {
            self.mqttClient = nil
        }
        if kind == .redis, let port = servicePort {
            self.redisClient = RedisClient(host: serviceHost, port: port,
                                           username: serviceUsername, password: servicePassword)
        } else {
            self.redisClient = nil
        }
        if kind == .finder {
            self.finderModel = LocalFileBrowser(startPath: startDirectory)
        } else {
            self.finderModel = nil
        }
        if kind == .editor {
            self.textEditorModel = TextEditorModel(path: startDirectory, backupID: editorBackupID)
        } else {
            self.textEditorModel = nil
        }
        if kind == .spreadsheet {
            self.spreadsheetModel = SpreadsheetModel(path: startDirectory)
        } else {
            self.spreadsheetModel = nil
        }
        super.init()
        terminalView.processDelegate = self
        // Detect URLs in the output and, when the user ⌘‑clicks one, open it in an
        // in‑app browser tab instead of the external browser. The proxy forwards
        // every other delegate message to the terminal's built‑in handling.
        terminalView.linkReporting = .implicit
        terminalView.linkHighlightMode = .hoverWithModifier
        let linkProxy = TerminalLinkDelegate(inner: terminalView)
        linkProxy.onOpenWebLink = { url in
            DispatchQueue.main.async {
                TerminalSessionManager.shared.openWeb(url: url, title: url.host ?? "Web")
            }
        }
        terminalView.terminalDelegate = linkProxy
        self.linkDelegate = linkProxy
        terminalView.onUserInput = { [weak self] data in self?.handleInput(data) }
        terminalView.onProcessOutput = { [weak self] data in self?.handleOutput(data) }
        terminalView.onZoom = { [weak self] direction in self?.zoom(direction) }
        terminalView.onAttachedToWindow = { [weak self] in self?.startIfPending() }
        terminalView.onLayout = { [weak self] in self?.startIfPending() }
        sftpClient?.onRunningChanged = { [weak self] running in
            self?.isRunning = running
            if !running { self?.exitCode = self?.exitCode ?? 0 }
        }
        vncClient?.onRunningChanged = { [weak self] running in
            self?.isRunning = running
            if !running { self?.exitCode = self?.exitCode ?? 0 }
        }
        mqttClient?.onRunningChanged = { [weak self] running in
            self?.isRunning = running
            if !running { self?.exitCode = self?.exitCode ?? 0 }
        }
        redisClient?.onRunningChanged = { [weak self] running in
            self?.isRunning = running
            if !running { self?.exitCode = self?.exitCode ?? 0 }
        }
        webModel?.onTitleChange = { [weak self] newTitle in
            let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { self?.title = trimmed }
        }
        webModel?.onPausedChange = { [weak self] _ in
            // Nudge the session so tab chips / dock headers re-evaluate `isPaused`.
            self?.pausedTick.toggle()
        }
        finderModel?.onPathChange = { [weak self] url in
            let name = url.lastPathComponent
            self?.title = name.isEmpty ? "/" : name
        }
        textEditorModel?.onTitleChange = { [weak self] newTitle in
            let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
            self?.title = trimmed.isEmpty ? "Untitled" : trimmed
        }
        textEditorModel?.refreshTitle()
        spreadsheetModel?.onTitleChange = { [weak self] newTitle in
            let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
            self?.title = trimmed.isEmpty ? "Untitled" : trimmed
        }
        spreadsheetModel?.refreshTitle()
        applyAppearance()
    }

    deinit { try? logHandle?.close() }

    private func applyAppearance() {
        terminalView.font = TerminalSession.font(ofSize: fontSize)
        theme.apply(to: terminalView)
    }

    /// The monospaced font used for the terminal at a given point size.
    private static func font(ofSize size: Double) -> NSFont {
        let s = CGFloat(size)
        return NSFont(name: "SF Mono", size: s)
            ?? NSFont(name: "Menlo", size: s)
            ?? NSFont.monospacedSystemFont(ofSize: s, weight: .regular)
    }

    func start() {
        guard !hasStarted else { return }

        if kind == .web {
            hasStarted = true
            isRunning = true
            exitCode = nil
            return
        }
        if kind == .sftp {
            hasStarted = true
            isRunning = true
            exitCode = nil
            sftpClient?.start()
            return
        }
        if kind == .vnc {
            hasStarted = true
            isRunning = true
            exitCode = nil
            vncClient?.start()
            return
        }
        if kind == .mqtt {
            hasStarted = true
            isRunning = true
            exitCode = nil
            mqttClient?.start()
            return
        }
        if kind == .redis {
            hasStarted = true
            isRunning = true
            exitCode = nil
            redisClient?.start()
            return
        }

        if kind == .finder {
            hasStarted = true
            isRunning = true
            exitCode = nil
            return
        }

        if kind == .editor || kind == .spreadsheet {
            hasStarted = true
            isRunning = true
            exitCode = nil
            return
        }

        // PTY-backed terminals (.localShell / .ssh) must be on screen at a real
        // size before we spawn, or SwiftTerm starts against a placeholder size and
        // the first screen never paints — what happens when a saved session is
        // restored before the window is shown, or when connecting routes into a
        // freshly-created workspace whose layout hasn't settled yet. Defer until
        // the view is attached *and* sized; `startIfPending()` (driven by
        // `onAttachedToWindow` / `onLayout`) resumes the start.
        guard terminalReadyToSpawn else {
            pendingStart = true
            return
        }

        hasStarted = true
        isRunning = true
        exitCode = nil
        autofillAttempts = 0
        cachedAutofillSecret = nil
        secretPromptActive = false
        userInitiatedStop = false
        runOnConnectFired = false
        openSessionLogIfNeeded()
        terminalView.startProcess(executable: executable,
                                  args: args,
                                  environment: TerminalSession.environment(extra: extraEnvironment),
                                  execName: nil,
                                  currentDirectory: startDirectory)
    }

    /// Called when the terminal view becomes part of a window. If a PTY start was
    /// deferred (view not yet on screen), run it now that the size is real.
    private func startIfPending() {
        guard pendingStart, !hasStarted else { return }
        pendingStart = false
        // One runloop turn so Auto Layout has given the view its final size.
        DispatchQueue.main.async { [weak self] in self?.start() }
    }

    /// Whether a PTY-backed terminal can be spawned: the view must be on screen
    /// at a usable size. Starting against a zero/placeholder size leaves the first
    /// screen blank (an apparent “connection error”), so we wait for real bounds.
    private var terminalReadyToSpawn: Bool {
        guard terminalView.window != nil else { return false }
        let bounds = terminalView.bounds
        return bounds.width > 32 && bounds.height > 24
    }

    /// Re-run the same command in this tab after it exited.
    func restart() {
        if kind == .web {
            isRunning = true
            exitCode = nil
            webModel?.reload()
            return
        }
        if kind == .sftp {
            isRunning = true
            exitCode = nil
            sftpClient?.reconnect()
            return
        }
        if kind == .vnc {
            isRunning = true
            exitCode = nil
            if let vncClient {
                vncClient.reconnect()   // the embedded viewer re-dials once the tunnel is up
            } else {
                embeddedVNCViewer?.connect()
            }
            return
        }
        if kind == .mqtt {
            isRunning = true
            exitCode = nil
            mqttClient?.reconnect()
            return
        }
        if kind == .redis {
            isRunning = true
            exitCode = nil
            redisClient?.reconnect()
            return
        }
        if kind == .finder {
            isRunning = true
            exitCode = nil
            finderModel?.reload()
            return
        }
        hasStarted = false
        start()
    }

    /// Stop the running process — closing an SSH tunnel (or ending a local shell)
    /// — **without removing the tab**. We hang up the child (`SIGHUP`, the same
    /// signal a PTY close would deliver); SwiftTerm's process monitor then fires
    /// `processTerminated`, which flips `isRunning` and shows the Reconnect banner,
    /// exactly as if the session had ended on its own. Use `close` on the manager
    /// to remove the tab entirely.
    func disconnect() {
        if kind == .web || kind == .finder || kind == .editor || kind == .spreadsheet {
            return
        }
        userInitiatedStop = true
        if kind == .sftp {
            sftpMounter?.unmountQuietly()
            sftpClient?.disconnect()
            return
        }
        if kind == .vnc {
            embeddedVNCViewer?.disconnect()
            vncClient?.disconnect()
            return
        }
        if kind == .mqtt {
            mqttClient?.disconnect()
            return
        }
        if kind == .redis {
            redisClient?.disconnect()
            return
        }
        guard isRunning, let pid = terminalView.process?.shellPid, pid > 0 else { return }
        kill(pid, SIGHUP)
    }

    /// Forcefully stop this session's underlying process(es) **right now**, instead
    /// of waiting for ARC to drop the last reference and let the PTY teardown send
    /// `SIGHUP`. A lingering strong reference (a still-mounted SwiftUI view, a
    /// capturing closure) would otherwise leave an SSH tunnel running as a "zombie"
    /// that keeps holding its forwarded ports — making the next connection to that
    /// profile collide on those ports and die (`ExitOnForwardFailure`). Used when
    /// closing a tab or quitting. Unlike `disconnect()`, this does not depend on the
    /// `isRunning` flag, so it still reaps a process whose state got out of sync.
    func shutDown() {
        userInitiatedStop = true
        closeSessionLog()
        switch kind {
        case .web:
            return
        case .finder:
            return
        case .editor:
            return
        case .spreadsheet:
            return
        case .sftp:
            sftpMounter?.unmountQuietly()
            sftpClient?.disconnect()
        case .vnc:
            embeddedVNCViewer?.disconnect()
            vncClient?.disconnect()
        case .mqtt:
            mqttClient?.disconnect()
        case .redis:
            redisClient?.disconnect()
        case .localShell, .ssh:
            if let pid = terminalView.process?.shellPid, pid > 0 {
                kill(pid, SIGHUP)
            }
        }
    }

    // MARK: - Command history

    /// Reconstruct typed command lines from the raw bytes sent to the shell.
    private func handleInput(_ data: ArraySlice<UInt8>) {
        guard !isInjecting else { return }
        // Mirror the keystrokes to every other terminal when broadcast is on.
        onUserTypedForBroadcast?(data)
        for byte in data { process(byte) }
    }

    /// Type broadcast keystrokes coming **from another terminal** into this one,
    /// without recording them to history or re-broadcasting them onward.
    func injectBroadcast(_ data: [UInt8]) {
        guard isRunning, kind == .ssh || kind == .localShell else { return }
        guard let text = String(bytes: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.isInjecting = true
            self.terminalView.send(txt: text)
            self.isInjecting = false
        }
    }

    private func process(_ byte: UInt8) {
        // Swallow escape sequences (arrow keys, function keys, bracketed-paste
        // markers, …) so they don't pollute the reconstructed line.
        switch escapeState {
        case .esc:
            escapeState = (byte == 0x5b /* [ */ || byte == 0x4f /* O */) ? .csi : .normal
            return
        case .csi:
            if (0x40...0x7e).contains(byte) { escapeState = .normal } // final byte
            return
        case .normal:
            break
        }

        switch byte {
        case 0x1b:              // ESC — start of an escape sequence
            escapeState = .esc
        case 0x0d, 0x0a:        // CR / LF — line submitted
            commitLine()
        case 0x7f, 0x08:        // DEL / Backspace
            if !lineBuffer.isEmpty { lineBuffer.removeLast() }
        case 0x03, 0x15:        // Ctrl-C / Ctrl-U — line abandoned / cleared
            lineBuffer.removeAll()
        case 0x00...0x1f:       // other control characters (Tab, etc.) — ignore
            break
        default:
            lineBuffer.append(byte)
        }
    }

    private func commitLine() {
        let bytes = lineBuffer
        lineBuffer.removeAll()
        // Never record what was typed at a password / passphrase prompt.
        guard !secretPromptActive else { return }
        guard let text = String(bytes: bytes, encoding: .utf8) else { return }
        let command = text.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return }
        addToHistory(command)
    }

    @discardableResult
    private func addToHistory(_ command: String) -> Bool {
        if commandHistory.last == command { return false }   // skip consecutive duplicate
        commandHistory.append(command)
        if commandHistory.count > historyLimit {
            commandHistory.removeFirst(commandHistory.count - historyLimit)
        }
        return true
    }

    /// Watch output to spot password prompts so the next submitted line isn't recorded.
    private func handleOutput(_ data: ArraySlice<UInt8>) {
        appendToSessionLog(data)
        recentOutputTail = String((recentOutputTail + String(decoding: data, as: UTF8.self)).suffix(400))
        // Strip ANSI colours / cursor moves first: a styled prompt like
        // "Password: \u{1b}[0m" would otherwise not end in ":" and slip past.
        let cleaned = TerminalSession.strippingTerminalControls(recentOutputTail)
        let lastLine = cleaned
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .last.map(String.init) ?? cleaned
        let wasActive = secretPromptActive
        secretPromptActive = TerminalSession.looksLikeSecretPrompt(lastLine)
        if secretPromptActive && !wasActive {
            maybeAutofillPassword()
        }
        maybeFireRunOnConnect()
    }

    /// Fire the profile's run-on-connect command once the shell looks ready: after
    /// the first output that isn't a password prompt, with a short settle delay so
    /// the login banner / shell prompt has landed. Re-arms if a prompt appears.
    private func maybeFireRunOnConnect() {
        guard let command = runOnConnectCommand, !runOnConnectFired, !secretPromptActive else { return }
        runOnConnectFired = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.isRunning else { return }
            if self.secretPromptActive {
                self.runOnConnectFired = false   // a prompt is up — wait for it to clear
                return
            }
            self.applyRunOnConnectTitle(command)
            self.run(command)
        }
    }

    /// Set (or clear) the command this tab auto-runs on launch. Normalises the
    /// value, so an empty/whitespace string disables it. When `runNow` is true and
    /// the shell is already running, the new command is also run immediately (so
    /// the user sees it take effect without reconnecting); otherwise it just arms
    /// for the next launch/reconnect.
    func setRunOnConnect(_ command: String, runNow: Bool = false) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        runOnConnectCommand = trimmed.isEmpty ? nil : trimmed
        runOnConnectFired = true   // don't let the output watcher double-fire it
        if let c = runOnConnectCommand {
            applyRunOnConnectTitle(c)
            if runNow, isRunning, !secretPromptActive { run(c) }
        }
    }

    /// Name the tab after the base program of its launch command — the first
    /// meaningful token, stripped of any path and switches (e.g. "tmux attach ||
    /// tmux new" → "tmux", "/usr/bin/htop -d 5" → "htop"). Leading environment
    /// assignments and common wrappers (sudo / env) are skipped so the name
    /// reflects the actual program. No-op if nothing usable is found.
    private func applyRunOnConnectTitle(_ command: String) {
        if let name = TerminalSession.baseCommandName(command) {
            title = name
        }
    }

    /// Extract the base program name from a shell command line. Splits on
    /// whitespace, skips `NAME=value` env assignments and the `sudo`/`env`
    /// wrappers, then returns the last path component of the first real token.
    /// Returns nil for an empty command or one that's only assignments/wrappers.
    static func baseCommandName(_ command: String) -> String? {
        let tokens = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        for token in tokens {
            // Skip env assignments (FOO=bar) and shell wrappers.
            if token.contains("=") && !token.hasPrefix("/") { continue }
            if token == "sudo" || token == "env" || token == "command" || token == "exec" { continue }
            // Skip leading switches (shouldn't lead, but be safe).
            if token.hasPrefix("-") { continue }
            let base = (token as NSString).lastPathComponent
            let cleaned = base.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }


    // MARK: - Session logging

    private static let logDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    /// Open this session's transcript log (once) when logging is enabled.
    private func openSessionLogIfNeeded() {
        guard sessionLoggingEnabled, logHandle == nil else { return }
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("SSHTunnelManager/Logs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = TerminalSession.logDateFormatter.string(from: Date())
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined(separator: "-").trimmingCharacters(in: .whitespaces)
        let url = dir.appendingPathComponent("\(safe.isEmpty ? "session" : safe)-\(stamp).log")
        fm.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        logHandle = handle
        sessionLogURL = url
        let header = "# \(title) — \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))\n# \(commandPreview)\n\n"
        if let data = header.data(using: .utf8) { handle.write(data) }
    }

    /// Append output to the transcript log (escape sequences stripped for reading).
    private func appendToSessionLog(_ data: ArraySlice<UInt8>) {
        guard let handle = logHandle else { return }
        let text = TerminalSession.strippingTerminalControls(String(decoding: data, as: UTF8.self))
        guard !text.isEmpty, let out = text.data(using: .utf8) else { return }
        handle.write(out)
    }

    private func closeSessionLog() {
        try? logHandle?.close()
        logHandle = nil
    }

    /// Whether a transcript log file exists for this session (drives the menu item).
    var hasSessionLog: Bool { sessionLogURL != nil }

    /// Reveal this session's transcript log in Finder.
    func revealSessionLog() {
        guard let url = sessionLogURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// On a password prompt, fetch the saved password (gated by Touch ID) and type
    /// it in. Fires at most `maxAutofillAttempts` times per connection: enough that
    /// a pre-auth banner mentioning "password:", or a bastion's own prompt, doesn't
    /// waste the fill on the wrong line — but few enough that a genuinely wrong
    /// stored password can't loop and lock the account.
    private func maybeAutofillPassword() {
        guard autofillAttempts < maxAutofillAttempts else { return }
        // An ad-hoc tab carries its typed password directly (no Keychain).
        if let preset = presetPassword, !preset.isEmpty {
            autofillAttempts += 1
            typeSecret(preset)
            return
        }
        // Otherwise autofill from a saved profile: the tab's own, or the profile
        // that launched its workspace (assigned to profile-free tabs rebuilt
        // inside a profile-launched workspace).
        guard let source = autofillPasswordSource else { return }
        // Reuse a password already unlocked this connection so a second prompt
        // doesn't pop Touch ID again.
        if let cached = cachedAutofillSecret {
            autofillAttempts += 1
            typeSecret(cached)
            return
        }
        autofillAttempts += 1
        KeychainStore.shared.password(
            for: source.profileID,
            requireAuth: source.requireAuth,
            reason: "Use the saved password for “\(title)”"
        ) { [weak self] result in
            guard let self, case .success(let password) = result else { return }
            self.rememberAutofillSecret(password)
            self.typeSecret(password)
        }
    }

    /// The profile whose Keychain password this tab should autofill, and whether
    /// Touch ID is required: its own profile when it autofills, otherwise an
    /// assigned owning-workspace profile. `nil` when the tab has no saved profile
    /// password to draw on.
    private var autofillPasswordSource: (profileID: UUID, requireAuth: Bool)? {
        if autofillPassword, let pid = profileID {
            return (pid, requireAuthForPassword)
        }
        if let pid = autofillSourceProfileID {
            return (pid, autofillSourceRequireAuth)
        }
        return nil
    }

    /// Type a secret into the terminal followed by Return, without recording it in
    /// history (the `isInjecting` flag suppresses capture). Always hops to main.
    private func typeSecret(_ secret: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.isInjecting = true
            self.terminalView.send(txt: secret)
            self.terminalView.send(txt: "\r")
            self.isInjecting = false
        }
    }

    /// Hold an unlocked password just long enough to answer a follow-up prompt
    /// without a second Touch ID, then forget it so it isn't kept in memory.
    private func rememberAutofillSecret(_ secret: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cachedAutofillSecret = secret
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
                self?.cachedAutofillSecret = nil
            }
        }
    }

    /// Remove ANSI/CSI/OSC escape sequences and other C0 control characters from
    /// terminal output, keeping newlines / carriage returns (our line separators)
    /// and printable text. Lets password-prompt detection see the plain text a
    /// server printed even when the prompt is coloured or cursor-positioned —
    /// otherwise stray escape bytes after the trailing ":" defeat the match.
    private static func strippingTerminalControls(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count)
        var i = 0
        while i < scalars.count {
            let u = scalars[i].value
            if u == 0x1b {                       // ESC — start of an escape sequence
                i += 1
                guard i < scalars.count else { break }
                let next = scalars[i].value
                if next == 0x5b {                // '[' → CSI: params… then a final @–~
                    i += 1
                    while i < scalars.count, !(0x40...0x7e).contains(scalars[i].value) { i += 1 }
                    if i < scalars.count { i += 1 }
                } else if next == 0x5d {         // ']' → OSC: … ended by BEL or ESC '\'
                    i += 1
                    while i < scalars.count, scalars[i].value != 0x07, scalars[i].value != 0x1b { i += 1 }
                    if i < scalars.count, scalars[i].value == 0x1b { i += 1 }
                    if i < scalars.count { i += 1 }
                } else {
                    i += 1                       // a two-character ESC sequence
                }
                continue
            }
            if u < 0x20, u != 0x0a, u != 0x0d {  // drop C0 controls except NL / CR
                i += 1
                continue
            }
            out.append(scalars[i])
            i += 1
        }
        return String(out)
    }

    private static func looksLikeSecretPrompt(_ line: String) -> Bool {
        let l = line.lowercased().trimmingCharacters(in: .whitespaces)
        guard l.hasSuffix(":") else { return false }
        return l.contains("password") || l.contains("passphrase")
    }

    /// Send a previous command back to the shell and run it.
    func rerun(_ command: String) {
        guard isRunning else { return }
        isInjecting = true
        terminalView.send(txt: "\u{15}")        // Ctrl-U: clear anything on the current line
        terminalView.send(txt: command)
        terminalView.send(txt: "\r")            // Enter
        isInjecting = false
        lineBuffer.removeAll()
        addToHistory(command)                   // promote to most-recent
    }

    func clearHistory() {
        commandHistory.removeAll()
    }

    // MARK: - Terminal buffer actions

    /// Clear the terminal display and scrollback (like Terminal.app's ⌘K). Feeds
    /// the erase sequence to the emulator, so it works the same for local shells
    /// and remote ssh sessions without sending anything to the running shell.
    func clearTerminal() {
        guard kind == .ssh || kind == .localShell else { return }
        DispatchQueue.main.async { [weak self] in
            // Erase scrollback (3J), home the cursor (H), erase the screen (2J).
            self?.terminalView.feed(text: "\u{1b}[3J\u{1b}[H\u{1b}[2J")
        }
    }

    /// The full terminal contents (scrollback + screen) as plain text, with
    /// trailing blank lines trimmed.
    var terminalBufferText: String {
        let data = terminalView.getTerminal().getBufferAsData()
        var text = String(decoding: data, as: UTF8.self)
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
        return text
    }

    /// Copy the entire terminal buffer to the clipboard.
    func copyTerminalBuffer() {
        let text = terminalBufferText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A sensible default file name for saved terminal output.
    var suggestedTerminalOutputFileName: String {
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-")
        let trimmed = safe.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(trimmed.isEmpty ? "Terminal" : trimmed) output.txt"
    }

    /// Import commands from plain text — one command per line — and append them to
    /// this tab's history (oldest first). Blank lines and comment lines (starting
    /// with `#`, e.g. the header written by Save History…) are skipped, and zsh
    /// EXTENDED_HISTORY timestamps (`: 1700000000:0;the command`) are unwrapped —
    /// so a file exported by this app, or a shell's own `.bash_history` /
    /// `.zsh_history`, can be imported. Returns the number of commands added.
    @discardableResult
    func importHistory(fromText text: String) -> Int {
        var added = 0
        for command in TerminalSession.parseHistoryLines(text) where addToHistory(command) {
            added += 1
        }
        return added
    }

    /// Extract runnable command lines from plain-text history (see `importHistory`).
    static func parseHistoryLines(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .compactMap { rawSlice -> String? in
                let raw = rawSlice.trimmingCharacters(in: .whitespaces)
                guard !raw.isEmpty, !raw.hasPrefix("#") else { return nil }
                let command = unwrapZshHistory(raw)
                return command.isEmpty ? nil : command
            }
    }

    /// Strip a leading zsh EXTENDED_HISTORY timestamp (`: <start>:<elapsed>;`) if
    /// present, returning the bare command. A line without that exact shape is
    /// returned unchanged, so a real command that merely starts with `:` (the
    /// shell no-op builtin) is preserved.
    private static func unwrapZshHistory(_ line: String) -> String {
        guard line.hasPrefix(": "), let semicolon = line.firstIndex(of: ";") else { return line }
        let meta = line[line.index(line.startIndex, offsetBy: 2)..<semicolon]
        let parts = meta.split(separator: ":")
        guard parts.count == 2, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return line }
        return String(line[line.index(after: semicolon)...]).trimmingCharacters(in: .whitespaces)
    }

    /// A plain-text rendering of this tab's command history for export (oldest
    /// first), with a short header. The header lines start with `#` so the file
    /// can still be sourced by a shell if desired.
    var historyExportText: String {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        var lines = ["# Command history — \(title)", "# Saved \(stamp)", ""]
        lines.append(contentsOf: commandHistory)
        return lines.joined(separator: "\n") + "\n"
    }

    /// A sensible default file name for the exported history.
    var suggestedHistoryFileName: String {
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-")
        let trimmed = safe.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(trimmed.isEmpty ? "Terminal" : trimmed) history.txt"
    }

    /// Insert text (e.g. a saved command snippet) at the prompt without running it.
    func paste(_ text: String) {
        guard isRunning else { return }
        terminalView.send(txt: text)
    }

    /// Insert a command and run it immediately (Enter), recording it to history.
    func run(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRunning, !trimmed.isEmpty else { return }
        isInjecting = true
        terminalView.send(txt: "\u{15}")        // Ctrl-U: clear the current line first
        terminalView.send(txt: trimmed)
        terminalView.send(txt: "\r")            // Enter
        isInjecting = false
        lineBuffer.removeAll()
        addToHistory(trimmed)
    }

    /// Whether this tab has a saved password we can type on demand — an ad-hoc
    /// tab's preset password, or a profile's Keychain password. Drives the
    /// right-click **Enter Saved Password** fallback.
    var hasSavedPasswordToSend: Bool {
        if let preset = presetPassword, !preset.isEmpty { return true }
        if let source = autofillPasswordSource {
            return KeychainStore.shared.hasPassword(for: source.profileID)
        }
        return false
    }

    /// Manually type this tab's saved password at the current prompt (Touch ID as
    /// the profile configures), without echoing it to history. A reliable fallback
    /// for when auto-fill doesn't recognise an unusual password prompt — and a
    /// quick way to tell the two apart: if this works but auto-fill didn't, the
    /// prompt wording is what auto-detection is missing.
    func sendSavedPassword() {
        guard isRunning else { return }
        if let preset = presetPassword, !preset.isEmpty {
            typeSecret(preset)
            return
        }
        guard let source = autofillPasswordSource else { return }
        KeychainStore.shared.password(
            for: source.profileID,
            requireAuth: source.requireAuth,
            reason: "Use the saved password for “\(title)”"
        ) { [weak self] result in
            guard let self, case .success(let password) = result else { return }
            self.typeSecret(password)
        }
    }

    /// Re-color a live terminal (used when a profile's theme is changed and saved).
    func applyTheme(_ newTheme: TerminalTheme) {
        theme = newTheme
        newTheme.apply(to: terminalView)
        terminalView.needsDisplay = true
    }

    // MARK: - Text size (⌘+ / ⌘− / ⌘0)

    /// Grow, shrink, or reset the terminal text — and remember the new size on the
    /// profile (SSH tabs) or the app default (plain local shells), so future tabs
    /// open at the same size.
    func zoom(_ direction: HistoryTerminalView.Zoom) {
        let target: Double
        switch direction {
        case .increase: target = fontSize + TerminalFontMetrics.step
        case .decrease: target = fontSize - TerminalFontMetrics.step
        case .reset:    target = TerminalFontMetrics.default
        }
        setFontSize(target)
    }

    /// Apply a specific text size to this terminal and persist it.
    func setFontSize(_ size: Double) {
        let clamped = TerminalFontMetrics.clamp(size)
        guard clamped != fontSize else { return }
        fontSize = clamped
        terminalView.font = TerminalSession.font(ofSize: clamped)
        terminalView.needsDisplay = true
        persistFontSize(clamped)
    }

    private func persistFontSize(_ size: Double) {
        if let id = profileID,
           var profile = ProfileStore.shared.profiles.first(where: { $0.id == id }) {
            if profile.fontSize != size {
                profile.fontSize = size
                ProfileStore.shared.update(profile)
            }
        } else {
            AppSettings.shared.defaultFontSize = size
        }
    }

    /// Build a sensible environment for the child process, merging any per-session
    /// extras (e.g. a service password passed out-of-band via an env var).
    static func environment(extra: [String: String] = [:]) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["LC_CTYPE"] = env["LC_CTYPE"] ?? "UTF-8"
        for (key, value) in extra { env[key] = value }
        return env.map { "\($0.key)=\($0.value)" }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Keep our tab title stable (the profile / shell name) rather than letting
        // the shell overwrite it, so users can always recognise their tunnels.
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        closeSessionLog()
        DispatchQueue.main.async {
            self.isRunning = false
            self.exitCode = exitCode
            self.tunnelHealth = .unknown
        }
    }
}
