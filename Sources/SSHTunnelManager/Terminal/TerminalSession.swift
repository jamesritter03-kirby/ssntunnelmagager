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
    }

    let kind: Kind
    @Published var title: String
    @Published var isRunning: Bool = true
    @Published var exitCode: Int32? = nil
    /// Commands typed in this tab, oldest first. Re-runnable from the history menu.
    @Published private(set) var commandHistory: [String] = []

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
    /// For local-shell sessions: the folder the shell should start in (nil = default).
    let startDirectory: String?

    let terminalView: HistoryTerminalView

    /// For `.sftp` sessions: the headless driver behind the graphical browser.
    let sftpClient: SFTPClient?

    /// For `.vnc` sessions: the headless ssh-tunnel driver behind the console.
    let vncClient: VNCClient?

    /// For `.web` sessions: the in-app browser tab's navigation model.
    let webModel: WebTabModel?

    /// For `.mqtt` sessions: the native MQTT broker client behind `MQTTExplorerView`.
    let mqttClient: MQTTClient?

    /// For `.redis` sessions: the native Redis client behind `RedisBrowserView`.
    let redisClient: RedisClient?

    /// For `.finder` sessions: the local file browser behind `FinderBrowserView`.
    let finderModel: LocalFileBrowser?

    /// For `.mqtt` / `.redis` sessions: the local (forwarded) port the native
    /// client connects to, kept so the tab can be recreated on the next launch.
    let servicePort: Int?

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
        case .ssh:        return "network"
        case .sftp:       return "arrow.up.arrow.down"
        case .vnc:        return "display"
        case .web:        return "globe"
        case .mqtt:       return "antenna.radiowaves.left.and.right"
        case .redis:      return "cylinder.split.1x2"
        case .finder:     return "folder"
        }
    }

    /// Remote sessions (ssh / sftp / vnc) and the native service clients
    /// (mqtt / redis) are live connections — “Disconnect”; local shells are “Stop”.
    var isRemote: Bool {
        kind == .ssh || kind == .sftp || kind == .vnc || kind == .mqtt || kind == .redis
    }

    /// Whether a per-command history makes sense for this tab: the interactive
    /// shells. (The mqtt / redis tabs are graphical clients, not REPLs.)
    var supportsCommandHistory: Bool {
        kind == .ssh || kind == .localShell
    }

    private var hasStarted = false

    // Command-line reconstruction state (see handleInput).
    private var lineBuffer: [UInt8] = []
    private var escapeState: LineEscapeState = .normal
    private var isInjecting = false
    private var secretPromptActive = false
    private var recentOutputTail = ""
    private let historyLimit = 300
    private var didAutofillPassword = false
    /// Set when a PTY start was requested before the view was on screen; the
    /// pending start runs once `startIfPending()` sees the view attached.
    private var pendingStart = false

    init(kind: Kind, title: String, executable: String, args: [String], commandPreview: String, profileID: UUID? = nil, theme: TerminalTheme = .default, fontSize: Double = TerminalFontMetrics.default, autofillPassword: Bool = false, requireAuthForPassword: Bool = true, startDirectory: String? = nil, webURL: URL? = nil, webProxy: WebProxy? = nil, servicePort: Int? = nil, serviceHost: String = "127.0.0.1", serviceUsername: String = "", servicePassword: String = "", extraEnvironment: [String: String] = [:]) {
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
        self.startDirectory = startDirectory
        self.servicePort = servicePort
        self.extraEnvironment = extraEnvironment
        self.terminalView = HistoryTerminalView(frame: NSRect(x: 0, y: 0, width: 820, height: 480))
        if kind == .sftp {
            self.sftpClient = SFTPClient(executable: executable, args: args, profileID: profileID,
                                         autofillPassword: autofillPassword,
                                         requireAuthForPassword: requireAuthForPassword)
        } else {
            self.sftpClient = nil
        }
        if kind == .vnc {
            self.vncClient = VNCClient(executable: executable, args: args, profileID: profileID,
                                       autofillPassword: autofillPassword,
                                       requireAuthForPassword: requireAuthForPassword)
        } else {
            self.vncClient = nil
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
        super.init()
        terminalView.processDelegate = self
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
        finderModel?.onPathChange = { [weak self] url in
            let name = url.lastPathComponent
            self?.title = name.isEmpty ? "/" : name
        }
        applyAppearance()
    }

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
        didAutofillPassword = false
        secretPromptActive = false
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
            vncClient?.reconnect()
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
        if kind == .web || kind == .finder {
            return
        }
        if kind == .sftp {
            sftpClient?.disconnect()
            return
        }
        if kind == .vnc {
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
        switch kind {
        case .web:
            return
        case .finder:
            return
        case .sftp:
            sftpClient?.disconnect()
        case .vnc:
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
        for byte in data { process(byte) }
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
        recentOutputTail = String((recentOutputTail + String(decoding: data, as: UTF8.self)).suffix(200))
        let lastLine = recentOutputTail
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .last.map(String.init) ?? recentOutputTail
        let wasActive = secretPromptActive
        secretPromptActive = TerminalSession.looksLikeSecretPrompt(lastLine)
        if secretPromptActive && !wasActive {
            maybeAutofillPassword()
        }
    }

    /// On the first password prompt, fetch the saved password (gated by Touch ID)
    /// and type it in. One-shot, so a wrong saved password can't cause a loop.
    private func maybeAutofillPassword() {
        guard autofillPassword, !didAutofillPassword, let pid = profileID else { return }
        didAutofillPassword = true
        KeychainStore.shared.password(
            for: pid,
            requireAuth: requireAuthForPassword,
            reason: "Use the saved password for “\(title)”"
        ) { [weak self] result in
            guard let self, case .success(let password) = result else { return }
            DispatchQueue.main.async {
                guard self.isRunning else { return }
                self.isInjecting = true
                self.terminalView.send(txt: password)
                self.terminalView.send(txt: "\r")
                self.isInjecting = false
            }
        }
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
        DispatchQueue.main.async {
            self.isRunning = false
            self.exitCode = exitCode
        }
    }
}
