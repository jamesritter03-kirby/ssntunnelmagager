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

    enum Kind: Equatable {
        case localShell
        case ssh
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

    let terminalView: HistoryTerminalView

    private var hasStarted = false

    // Command-line reconstruction state (see handleInput).
    private var lineBuffer: [UInt8] = []
    private var escapeState: LineEscapeState = .normal
    private var isInjecting = false
    private var secretPromptActive = false
    private var recentOutputTail = ""
    private let historyLimit = 300
    private var didAutofillPassword = false

    init(kind: Kind, title: String, executable: String, args: [String], commandPreview: String, profileID: UUID? = nil, theme: TerminalTheme = .default, fontSize: Double = TerminalFontMetrics.default, autofillPassword: Bool = false, requireAuthForPassword: Bool = true) {
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
        self.terminalView = HistoryTerminalView(frame: NSRect(x: 0, y: 0, width: 820, height: 480))
        super.init()
        terminalView.processDelegate = self
        terminalView.onUserInput = { [weak self] data in self?.handleInput(data) }
        terminalView.onProcessOutput = { [weak self] data in self?.handleOutput(data) }
        terminalView.onZoom = { [weak self] direction in self?.zoom(direction) }
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
        hasStarted = true
        isRunning = true
        exitCode = nil
        didAutofillPassword = false
        secretPromptActive = false
        terminalView.startProcess(executable: executable,
                                  args: args,
                                  environment: TerminalSession.environment(),
                                  execName: nil)
    }

    /// Re-run the same command in this tab after it exited.
    func restart() {
        hasStarted = false
        start()
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

    private func addToHistory(_ command: String) {
        if commandHistory.last == command { return }   // skip consecutive duplicate
        commandHistory.append(command)
        if commandHistory.count > historyLimit {
            commandHistory.removeFirst(commandHistory.count - historyLimit)
        }
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

    /// Build a sensible environment for the child process.
    static func environment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["LC_CTYPE"] = env["LC_CTYPE"] ?? "UTF-8"
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
