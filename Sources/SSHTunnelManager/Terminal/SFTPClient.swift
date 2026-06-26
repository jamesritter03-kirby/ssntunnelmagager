import Foundation
import AppKit
import SwiftTerm

/// One entry in a remote directory listing (parsed from `ls -la`).
struct SFTPEntry: Identifiable, Hashable {
    enum Kind { case directory, file, symlink, other }

    let name: String
    let kind: Kind
    let size: Int64
    let modified: String
    let permissions: String
    let symlinkTarget: String?

    var id: String { name }
    var isDirectory: Bool { kind == .directory }

    var systemImage: String {
        switch kind {
        case .directory: return "folder.fill"
        case .symlink:   return "arrowshape.turn.up.right.circle.fill"
        case .file:      return "doc.fill"
        case .other:     return "questionmark.square.fill"
        }
    }

    /// Human-readable size (files only).
    var displaySize: String {
        guard kind != .directory else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

extension SFTPEntry {
    /// Parse one `ls -la` long-format line into an entry, or nil if it isn't a
    /// file row (headers like `total 8`, and the `.`/`..` entries return nil).
    static func parse(line rawLine: String) -> SFTPEntry? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard let typeChar = line.first, "dl-bcsp".contains(typeChar) else { return nil }
        guard let (fields, rest) = splitLeading(line, count: 8), fields.count == 8 else { return nil }

        let perms = fields[0]
        guard perms.count >= 10 else { return nil }
        let size = Int64(fields[4]) ?? 0
        let modified = "\(fields[5]) \(fields[6]) \(fields[7])"

        var name = rest
        var target: String? = nil
        let kind: Kind
        switch typeChar {
        case "d": kind = .directory
        case "l":
            kind = .symlink
            if let r = name.range(of: " -> ") {
                target = String(name[r.upperBound...])
                name = String(name[..<r.lowerBound])
            }
        case "-": kind = .file
        default:  kind = .other
        }

        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        return SFTPEntry(name: name, kind: kind, size: size,
                         modified: modified, permissions: perms, symlinkTarget: target)
    }

    /// Split a line into the first `count` whitespace-delimited fields plus the
    /// remaining substring (preserving the original internal spacing) as the name.
    private static func splitLeading(_ line: String, count: Int) -> (fields: [String], rest: String)? {
        var fields: [String] = []
        var idx = line.startIndex
        let end = line.endIndex
        func skipSpaces() {
            while idx < end, line[idx] == " " || line[idx] == "\t" { idx = line.index(after: idx) }
        }
        for _ in 0..<count {
            skipSpaces()
            guard idx < end else { return nil }
            let start = idx
            while idx < end, line[idx] != " ", line[idx] != "\t" { idx = line.index(after: idx) }
            fields.append(String(line[start..<idx]))
        }
        skipSpaces()
        return (fields, String(line[idx..<end]))
    }
}

/// Drives a headless interactive `sftp` process (PTY-backed via SwiftTerm's
/// `LocalProcess`) and exposes a graphical file-browser model: a parsed remote
/// listing, current directory, and async file operations.
///
/// Commands are run one at a time using a unique sentinel (`!echo <marker>`) so
/// we know when each command's output is complete, even though the PTY echoes
/// input. Authentication (password autofill / host-key confirmation) reuses the
/// same approach as the terminal sessions.
final class SFTPClient: NSObject, ObservableObject, LocalProcessDelegate {
    enum Phase: Equatable {
        case idle
        case connecting
        case ready
        case busy
        case failed(String)
        case ended
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var entries: [SFTPEntry] = []
    @Published private(set) var currentPath: String = ""
    @Published private(set) var transcript: String = ""
    @Published var statusMessage: String = ""
    @Published var errorMessage: String?

    /// Folder downloads are saved into. Defaults to ~/Downloads.
    @Published var localDownloadDirectory: URL =
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser

    /// The owning session mirrors this to drive the tab's running indicator.
    var onRunningChanged: ((Bool) -> Void)?

    var isConnected: Bool { phase == .ready || phase == .busy }
    var isBusy: Bool { phase == .busy }

    private let executable: String
    private let args: [String]
    private let profileID: UUID?
    private let autofillPassword: Bool
    private let requireAuthForPassword: Bool

    private var process: LocalProcess!
    private var rawBuffer = ""
    private var pendingBuffer = ""
    private var queue: [Command] = []
    private var current: Command?
    private var markerCounter = 0
    private var currentMarker = ""
    private var didAutofillPassword = false
    private var handlingAuthPrompt = false

    private struct Command {
        let text: String
        let status: String?
        let completion: (String) -> Void
    }

    init(executable: String, args: [String], profileID: UUID?,
         autofillPassword: Bool, requireAuthForPassword: Bool) {
        self.executable = executable
        self.args = args
        self.profileID = profileID
        self.autofillPassword = autofillPassword
        self.requireAuthForPassword = requireAuthForPassword
        super.init()
        process = LocalProcess(delegate: self, dispatchQueue: .main)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isConnected, phase != .connecting else { return }
        rawBuffer = ""
        pendingBuffer = ""
        queue.removeAll()
        current = nil
        didAutofillPassword = false
        handlingAuthPrompt = false
        entries = []
        errorMessage = nil
        phase = .connecting
        statusMessage = "Connecting…"
        onRunningChanged?(true)

        // Force a dumb terminal + a very wide line so sftp/libedit don't emit
        // cursor escapes or wrap the echoed command lines.
        var env = TerminalSession.environment().filter { !$0.hasPrefix("TERM=") }
        env.append("TERM=dumb")
        process.startProcess(executable: executable, args: args, environment: env, execName: nil)
    }

    /// Gracefully end the session (used by Disconnect).
    func disconnect() {
        guard isConnected || phase == .connecting else { return }
        let pid = process.shellPid
        if process.running { sendRaw("\nbye\n") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            if self.process.running, pid > 0 { kill(pid, SIGHUP) }
        }
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
        if case .failed = phase {} else { phase = .ended; statusMessage = "Disconnected" }
        current = nil
        queue.removeAll()
        onRunningChanged?(false)
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        ingest(SFTPClient.stripANSI(String(decoding: slice, as: UTF8.self)))
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: 50, ws_col: 1000, ws_xpixel: 0, ws_ypixel: 0)
    }

    // MARK: - Output handling

    private func ingest(_ text: String) {
        transcript += text
        if transcript.count > 80_000 { transcript = String(transcript.suffix(50_000)) }

        switch phase {
        case .connecting:
            rawBuffer += text
            handleConnecting()
        case .busy:
            pendingBuffer += text
            handleBusy()
        default:
            break
        }
    }

    private func handleConnecting() {
        guard !handlingAuthPrompt else { return }
        if let line = SFTPClient.lastNonEmptyLine(rawBuffer) {
            if SFTPClient.looksLikeSecretPrompt(line) { handleSecretPrompt(); return }
            if SFTPClient.looksLikeHostKeyPrompt(rawBuffer) { handleHostKeyPrompt(); return }
        }
        if let failure = SFTPClient.failureMessage(in: rawBuffer) { fail(failure); return }
        if rawBuffer.contains("sftp>") {
            rawBuffer = ""
            phase = .ready
            statusMessage = "Connected"
            refresh()
        }
    }

    private func handleBusy() {
        guard let cmd = current,
              let markerRange = SFTPClient.markerLineRange(currentMarker, in: pendingBuffer)
        else { return }
        let region = String(pendingBuffer[..<markerRange.lowerBound])
        let output = SFTPClient.extractOutput(region: region, command: cmd.text, marker: currentMarker)
        pendingBuffer = ""
        current = nil
        phase = .ready
        cmd.completion(output)
        if phase == .ready { statusMessage = defaultStatus() }
        pump()
    }

    // MARK: - Auth

    private func handleSecretPrompt() {
        handlingAuthPrompt = true
        rawBuffer = ""
        if !didAutofillPassword, autofillPassword, let pid = profileID {
            didAutofillPassword = true
            KeychainStore.shared.password(for: pid, requireAuth: requireAuthForPassword,
                                          reason: "Use the saved password for SFTP") { [weak self] result in
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
        alert.informativeText = "Enter the password for this SFTP connection."
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
        let detail = rawBuffer
        rawBuffer = ""
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

    // MARK: - Command queue

    private func runCommand(_ text: String, status: String? = nil,
                            completion: @escaping (String) -> Void = { _ in }) {
        queue.append(Command(text: text, status: status, completion: completion))
        pump()
    }

    private func pump() {
        guard phase == .ready, current == nil, !queue.isEmpty else { return }
        let cmd = queue.removeFirst()
        current = cmd
        phase = .busy
        if let s = cmd.status { statusMessage = s }
        pendingBuffer = ""
        markerCounter += 1
        currentMarker = "__SFTPDONE_\(markerCounter)__"
        sendRaw(cmd.text + "\n")
        sendRaw("!echo " + currentMarker + "\n")
    }

    private func sendRaw(_ s: String) {
        let bytes = Array(s.utf8)
        process.send(data: bytes[...])
    }

    // MARK: - High-level operations

    func refresh() {
        runCommand("pwd", status: "Loading…") { [weak self] out in
            if let path = SFTPClient.parsePwd(out) { self?.currentPath = path }
        }
        runCommand("ls -la") { [weak self] out in
            guard let self else { return }
            self.entries = SFTPClient.parseListing(out)
            self.statusMessage = self.defaultStatus()
        }
    }

    func changeDirectory(to path: String) {
        runCommand("cd \(SFTPCommandBuilder.quotePath(path))", status: "Opening…") { [weak self] out in
            if let problem = SFTPClient.operationError(out) { self?.report(problem) }
        }
        refresh()
    }

    func goUp() { changeDirectory(to: "..") }

    func open(_ entry: SFTPEntry) {
        if entry.isDirectory || entry.kind == .symlink {
            changeDirectory(to: entry.name)
        } else {
            download([entry])
        }
    }

    func upload(_ urls: [URL]) {
        guard isConnected else { return }
        let total = urls.count
        for (index, url) in urls.enumerated() {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let q = SFTPCommandBuilder.quotePath(url.path)
            let cmd = isDir.boolValue ? "put -r \(q)" : "put \(q)"
            let label = total > 1
                ? "Uploading \(url.lastPathComponent) (\(index + 1) of \(total))…"
                : "Uploading \(url.lastPathComponent)…"
            runCommand(cmd, status: label) { [weak self] out in
                if let problem = SFTPClient.operationError(out) { self?.report(problem) }
            }
        }
        refresh()
    }

    /// Upload files/folders **into a subfolder** of the current directory — used
    /// when the user drags a drop onto a specific folder row (rather than the
    /// list as a whole). `folderName` is a child of `currentPath`; each item is
    /// sent to `folderName/<item name>` so it lands inside that folder.
    func upload(_ urls: [URL], into folderName: String) {
        guard isConnected else { return }
        let total = urls.count
        for (index, url) in urls.enumerated() {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let localQ = SFTPCommandBuilder.quotePath(url.path)
            let remoteQ = SFTPCommandBuilder.quotePath(folderName + "/" + url.lastPathComponent)
            let cmd = isDir.boolValue ? "put -r \(localQ) \(remoteQ)" : "put \(localQ) \(remoteQ)"
            let label = total > 1
                ? "Uploading \(url.lastPathComponent) → \(folderName) (\(index + 1) of \(total))…"
                : "Uploading \(url.lastPathComponent) → \(folderName)…"
            runCommand(cmd, status: label) { [weak self] out in
                if let problem = SFTPClient.operationError(out) { self?.report(problem) }
            }
        }
        refresh()
    }

    func download(_ entries: [SFTPEntry], reveal: Bool = true) {
        guard isConnected else { return }
        let dir = localDownloadDirectory
        var saved: [URL] = []
        let total = entries.count
        for (index, entry) in entries.enumerated() {
            let rq = SFTPCommandBuilder.quotePath(entry.name)
            let lq = SFTPCommandBuilder.quotePath(dir.path)
            let recurse = entry.isDirectory ? "-r " : ""
            saved.append(dir.appendingPathComponent(entry.name))
            let label = total > 1
                ? "Downloading \(entry.name) (\(index + 1) of \(total))…"
                : "Downloading \(entry.name)…"
            runCommand("get \(recurse)\(rq) \(lq)", status: label) { [weak self] out in
                guard let self else { return }
                if let problem = SFTPClient.operationError(out) { self.report(problem) }
            }
        }
        if reveal {
            runCommand("pwd") { [weak self] _ in
                guard self != nil, !saved.isEmpty else { return }
                NSWorkspace.shared.activateFileViewerSelecting(saved)
            }
        }
    }

    func makeDirectory(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        runCommand("mkdir \(SFTPCommandBuilder.quotePath(trimmed))", status: "Creating \(trimmed)…") { [weak self] out in
            if let problem = SFTPClient.operationError(out) { self?.report(problem) }
        }
        refresh()
    }

    func remove(_ entry: SFTPEntry) {
        let q = SFTPCommandBuilder.quotePath(entry.name)
        let cmd = entry.isDirectory ? "rmdir \(q)" : "rm \(q)"
        runCommand(cmd, status: "Deleting \(entry.name)…") { [weak self] out in
            if let problem = SFTPClient.operationError(out) { self?.report(problem) }
        }
        refresh()
    }

    func rename(_ entry: SFTPEntry, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != entry.name else { return }
        runCommand("rename \(SFTPCommandBuilder.quotePath(entry.name)) \(SFTPCommandBuilder.quotePath(trimmed))",
                   status: "Renaming…") { [weak self] out in
            if let problem = SFTPClient.operationError(out) { self?.report(problem) }
        }
        refresh()
    }

    private func report(_ message: String) {
        errorMessage = message
        statusMessage = message
    }

    private func defaultStatus() -> String {
        let n = entries.count
        return "\(n) item\(n == 1 ? "" : "s")"
    }

    // MARK: - Parsing helpers

    static func parseListing(_ output: String) -> [SFTPEntry] {
        let entries = output
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .compactMap { SFTPEntry.parse(line: String($0)) }
        return entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    static func parsePwd(_ output: String) -> String? {
        for raw in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if let r = line.range(of: "Remote working directory:") {
                return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("/") || line.hasPrefix("~") { return line }
        }
        return nil
    }

    /// Build the command's output region: drop echoed input, prompts and the marker.
    static func extractOutput(region: String, command: String, marker: String) -> String {
        let normalized = region
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let cmd = command.trimmingCharacters(in: .whitespaces)
        var result: [String] = []
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripPromptPrefix(String(rawLine))
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t == cmd { continue }
            if t == "!echo \(marker)" { continue }
            if t == marker { continue }
            if t.hasPrefix("sftp>") { continue }
            result.append(line)
        }
        return result.joined(separator: "\n")
    }

    private static func stripPromptPrefix(_ s: String) -> String {
        var line = s
        while line.hasPrefix("sftp> ") { line.removeFirst("sftp> ".count) }
        return line
    }

    /// Find the marker on its *output* line — i.e. alone on a line, possibly
    /// preceded by one or more `sftp> ` prompt prefixes and/or whitespace
    /// (sftp echoes the `!echo` output as `sftp> __SFTPDONE_n__`). This must NOT
    /// match the echoed *input* line, where the marker is preceded by `!echo `
    /// (e.g. `sftp> !echo __SFTPDONE_n__`). Returns a range starting at the
    /// beginning of the marker's physical line so the caller can slice the
    /// command output cleanly before it.
    static func markerLineRange(_ marker: String, in buffer: String) -> Range<String.Index>? {
        var searchStart = buffer.startIndex
        while let r = buffer.range(of: marker, range: searchStart..<buffer.endIndex) {
            // Walk back to the start of the physical line containing this hit.
            // Note: Swift treats "\r\n" as a single Character, so compare with
            // `.isNewline` rather than against "\n"/"\r" individually.
            var lineStart = r.lowerBound
            while lineStart > buffer.startIndex {
                let prev = buffer.index(before: lineStart)
                if buffer[prev].isNewline { break }
                lineStart = prev
            }
            // The marker must reach the end of its line (only whitespace after).
            var nextBoundary = true
            var i = r.upperBound
            while i < buffer.endIndex {
                let c = buffer[i]
                if c.isNewline { break }
                if c != " " && c != "\t" { nextBoundary = false; break }
                i = buffer.index(after: i)
            }
            // Everything before the marker on this line, after removing prompt
            // prefixes and whitespace, must be empty — otherwise it's the echoed
            // `!echo …` input line and should be ignored.
            var prefix = String(buffer[lineStart..<r.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            while prefix.hasPrefix("sftp>") {
                prefix.removeFirst("sftp>".count)
                prefix = prefix.trimmingCharacters(in: .whitespaces)
            }
            if prefix.isEmpty && nextBoundary {
                return lineStart..<r.upperBound
            }
            searchStart = r.upperBound
        }
        return nil
    }

    static func stripANSI(_ s: String) -> String {
        var result = s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]",
                                             with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)",
                                              with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\u{1B}[=>]", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\u{07}", with: "")
        return result
    }

    static func lastNonEmptyLine(_ s: String) -> String? {
        s.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    static func looksLikeSecretPrompt(_ line: String) -> Bool {
        let l = line.lowercased().trimmingCharacters(in: .whitespaces)
        guard l.hasSuffix(":") else { return false }
        return l.contains("password") || l.contains("passphrase")
    }

    static func looksLikeHostKeyPrompt(_ buffer: String) -> Bool {
        buffer.contains("(yes/no") || buffer.contains("fingerprint)?")
    }

    static func failureMessage(in buffer: String) -> String? {
        let patterns: [(String, String)] = [
            ("Could not resolve hostname", "Could not resolve the host name."),
            ("Name or service not known", "Could not resolve the host name."),
            ("Connection refused", "Connection refused."),
            ("Connection closed", "The connection was closed."),
            ("Connection timed out", "The connection timed out."),
            ("Operation timed out", "The connection timed out."),
            ("No route to host", "No route to host."),
            ("Permission denied (", "Permission denied — check your username, key or password."),
            ("Too many authentication failures", "Too many authentication failures."),
            ("Host key verification failed", "Host key verification failed."),
            ("not a regular file", "Remote path is not a regular file."),
        ]
        for (needle, message) in patterns where buffer.contains(needle) {
            return message
        }
        return nil
    }

    /// Detect a per-operation error line in sftp output (so callers can surface it).
    static func operationError(_ output: String) -> String? {
        for raw in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Couldn't") || line.hasPrefix("Cannot")
                || line.contains("No such file or directory")
                || line.contains("Permission denied")
                || line.contains("Failure") {
                return line
            }
        }
        return nil
    }
}

