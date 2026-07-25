import Foundation

/// The outcome of a Git sync operation, with a human-readable log.
struct GitSyncResult {
    let success: Bool
    let log: String
}

/// Persisted Git-sync configuration (remote URL + branch).
struct GitSyncConfig: Codable {
    var remoteUrl: String = ""
    var branch: String = "main"
}

/// Syncs the user's `profiles.json` with a Git repository (e.g. a private GitHub
/// repo) so profiles can be shared between machines. A local working copy is kept
/// under the app-support dir next to `profiles.json`; **Pull** copies the repo's
/// profiles back into the store, **Push** commits the store's profiles and (if a
/// remote is set) pushes them.
///
/// The system `git` CLI is invoked directly via `Process` (never through a shell),
/// so a user-supplied remote URL can never be interpreted as a command. Passwords
/// are *not* stored in profiles.json (they live in the Keychain), so nothing secret
/// is ever committed.
final class GitProfileSync {
    private static let profilesFileName = "profiles.json"

    private let profilesPath: String
    private let repoDir: String
    private let configPath: String

    private(set) var config = GitSyncConfig()

    /// Absolute path of the local Git working copy.
    var repoDirectory: String { repoDir }

    init(profilesPath: String) {
        self.profilesPath = profilesPath
        let appDir = (profilesPath as NSString).deletingLastPathComponent
        self.repoDir = (appDir as NSString).appendingPathComponent("profiles-repo")
        self.configPath = (appDir as NSString).appendingPathComponent("git-sync.json")
        loadConfig()
    }

    // MARK: - Config

    private func loadConfig() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let loaded = try? JSONDecoder().decode(GitSyncConfig.self, from: data) {
            config = loaded
        }
        if config.branch.trimmingCharacters(in: .whitespaces).isEmpty {
            config.branch = "main"
        }
    }

    func saveConfig(remoteUrl: String, branch: String) {
        config.remoteUrl = remoteUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        config.branch = b.isEmpty ? "main" : b
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            try? data.write(to: URL(fileURLWithPath: configPath), options: [.atomic])
        }
    }

    private var repoInitialized: Bool {
        FileManager.default.fileExists(atPath: (repoDir as NSString).appendingPathComponent(".git"))
    }

    // MARK: - Operations

    /// Clone the configured remote (or `git init` a fresh local repo).
    func initOrClone() async -> GitSyncResult {
        let log = LogBuffer()
        guard await gitAvailable(log) else { return GitSyncResult(success: false, log: log.text) }

        if repoInitialized {
            log.line("Repository already initialised at:")
            log.line("  " + repoDir)
            return GitSyncResult(success: true, log: log.text)
        }

        let fm = FileManager.default
        try? fm.createDirectory(atPath: repoDir, withIntermediateDirectories: true)

        let remote = config.remoteUrl.trimmingCharacters(in: .whitespaces)
        if !remote.isEmpty {
            // Clone into a temp dir then move it in, since `git clone` needs an empty target.
            let parent = (repoDir as NSString).deletingLastPathComponent
            let tmpClone = (parent as NSString).appendingPathComponent("profiles-repo.clone-" + UUID().uuidString)
            var (code, _) = await runGit(in: parent, log: log, "clone", "--branch", config.branch, remote, tmpClone)
            if code != 0 {
                // The branch may not exist yet on a brand-new remote — clone the default branch.
                log.line("Retrying clone without an explicit branch…")
                (code, _) = await runGit(in: parent, log: log, "clone", remote, tmpClone)
            }
            if code != 0 {
                tryDelete(tmpClone)
                return GitSyncResult(success: false, log: log.text)
            }
            tryDelete(repoDir)
            try? fm.moveItem(atPath: tmpClone, toPath: repoDir)
            _ = await runGit(in: repoDir, log: log, "checkout", "-B", config.branch)
            log.line("Cloned into local working copy.")
            return GitSyncResult(success: true, log: log.text)
        }

        // No remote: start a local-only repository.
        _ = await runGit(in: repoDir, log: log, "init")
        _ = await runGit(in: repoDir, log: log, "checkout", "-B", config.branch)
        log.line("Initialised a local Git repository (no remote configured).")
        return GitSyncResult(success: true, log: log.text)
    }

    /// Pull the latest profiles from the repo and copy them onto the live store file.
    func pull() async -> GitSyncResult {
        let log = LogBuffer()
        guard await gitAvailable(log) else { return GitSyncResult(success: false, log: log.text) }

        if !repoInitialized {
            let initResult = await initOrClone()
            log.append(initResult.log)
            if !initResult.success { return GitSyncResult(success: false, log: log.text) }
        }

        if !config.remoteUrl.trimmingCharacters(in: .whitespaces).isEmpty {
            await ensureRemote(log)
            let (code, _) = await runGit(in: repoDir, log: log, "pull", "--no-rebase", "origin", config.branch)
            if code != 0 { return GitSyncResult(success: false, log: log.text) }
        }

        let repoProfiles = (repoDir as NSString).appendingPathComponent(Self.profilesFileName)
        guard FileManager.default.fileExists(atPath: repoProfiles) else {
            log.line("No profiles.json in the repo yet — nothing to import. Push first.")
            return GitSyncResult(success: true, log: log.text)
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: repoProfiles))
            try data.write(to: URL(fileURLWithPath: profilesPath), options: [.atomic])
            log.line("Imported profiles.json from the repository into the app.")
            return GitSyncResult(success: true, log: log.text)
        } catch {
            log.line("Failed to copy profiles into the app: \(error.localizedDescription)")
            return GitSyncResult(success: false, log: log.text)
        }
    }

    /// Copy the live profiles into the repo, commit, and push (if a remote is set).
    func push(commitMessage: String?) async -> GitSyncResult {
        let log = LogBuffer()
        guard await gitAvailable(log) else { return GitSyncResult(success: false, log: log.text) }

        if !repoInitialized {
            let initResult = await initOrClone()
            log.append(initResult.log)
            if !initResult.success { return GitSyncResult(success: false, log: log.text) }
        }

        guard FileManager.default.fileExists(atPath: profilesPath) else {
            log.line("No local profiles.json to push.")
            return GitSyncResult(success: false, log: log.text)
        }

        let repoProfiles = (repoDir as NSString).appendingPathComponent(Self.profilesFileName)
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: profilesPath))
            try data.write(to: URL(fileURLWithPath: repoProfiles), options: [.atomic])
        } catch {
            log.line("Failed to stage profiles into the repo: \(error.localizedDescription)")
            return GitSyncResult(success: false, log: log.text)
        }

        _ = await runGit(in: repoDir, log: log, "add", Self.profilesFileName)

        // Nothing staged => no commit needed.
        let (statusCode, status) = await runGit(in: repoDir, log: log, "status", "--porcelain")
        if statusCode == 0 && status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log.line("Profiles already up to date — nothing to commit.")
        } else {
            let trimmed = (commitMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = trimmed.isEmpty ? "Update profiles \(Self.timestamp())" : trimmed
            let (commitCode, _) = await runGit(in: repoDir, log: log, "commit", "-m", msg)
            if commitCode != 0 { return GitSyncResult(success: false, log: log.text) }
        }

        if !config.remoteUrl.trimmingCharacters(in: .whitespaces).isEmpty {
            await ensureRemote(log)
            let (pushCode, _) = await runGit(in: repoDir, log: log, "push", "-u", "origin", config.branch)
            if pushCode != 0 { return GitSyncResult(success: false, log: log.text) }
            log.line("Pushed profiles to the remote.")
        } else {
            log.line("Committed locally (no remote configured to push to).")
        }

        return GitSyncResult(success: true, log: log.text)
    }

    /// Show the working-copy status.
    func status() async -> GitSyncResult {
        let log = LogBuffer()
        guard await gitAvailable(log) else { return GitSyncResult(success: false, log: log.text) }
        if !repoInitialized {
            log.line("No local repository yet. Use “Init / Clone”.")
            return GitSyncResult(success: true, log: log.text)
        }
        _ = await runGit(in: repoDir, log: log, "status", "--short", "--branch")
        return GitSyncResult(success: true, log: log.text)
    }

    // MARK: - Helpers

    private func ensureRemote(_ log: LogBuffer) async {
        let (code, url) = await runGit(in: repoDir, log: log, quiet: true, "remote", "get-url", "origin")
        if code != 0 {
            _ = await runGit(in: repoDir, log: log, "remote", "add", "origin", config.remoteUrl)
        } else if url.trimmingCharacters(in: .whitespacesAndNewlines) != config.remoteUrl {
            _ = await runGit(in: repoDir, log: log, "remote", "set-url", "origin", config.remoteUrl)
        }
    }

    private func gitAvailable(_ log: LogBuffer) async -> Bool {
        let (code, _) = await runGit(in: NSTemporaryDirectory(), log: log, quiet: true, "--version")
        if code == 0 { return true }
        log.line("Git is not available. Install the Xcode Command Line Tools or Git and try again.")
        return false
    }

    private func runGit(in workingDir: String, log: LogBuffer, _ args: String...) async -> (code: Int32, output: String) {
        await runGit(in: workingDir, log: log, quiet: false, args)
    }

    private func runGit(in workingDir: String, log: LogBuffer, quiet: Bool, _ args: String...) async -> (code: Int32, output: String) {
        await runGit(in: workingDir, log: log, quiet: quiet, args)
    }

    private func runGit(in workingDir: String, log: LogBuffer, quiet: Bool, _ args: [String]) async -> (code: Int32, output: String) {
        await withCheckedContinuation { continuation in
            // Run the blocking process work on a background queue so we never stall
            // a Swift-concurrency cooperative thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                // Resolve git via /usr/bin/env so it honours the user's PATH and the
                // Xcode Command Line Tools shim, without invoking a shell.
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["git"] + args
                process.currentDirectoryURL = URL(fileURLWithPath: workingDir)
                var env = ProcessInfo.processInfo.environment
                // Never let git block on an interactive credential prompt.
                env["GIT_TERMINAL_PROMPT"] = "0"
                process.environment = env

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                if !quiet { log.line("$ git " + args.joined(separator: " ")) }

                do {
                    try process.run()
                } catch {
                    log.line("  error: \(error.localizedDescription)")
                    continuation.resume(returning: (-1, ""))
                    return
                }

                // Drain both pipes concurrently: reading them serially can deadlock
                // when one fills its 64 KB buffer (e.g. `git clone` progress on
                // stderr) while we're blocked reading the other.
                var outData = Data()
                var errData = Data()
                let group = DispatchGroup()
                let readQueue = DispatchQueue.global(qos: .userInitiated)
                group.enter()
                readQueue.async { outData = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter()
                readQueue.async { errData = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                process.waitUntilExit()
                group.wait()

                let outText = String(data: outData, encoding: .utf8) ?? ""
                let errText = String(data: errData, encoding: .utf8) ?? ""
                if !quiet {
                    if !outText.isEmpty { log.append(outText) }
                    if !errText.isEmpty { log.append(errText) }
                }
                continuation.resume(returning: (process.terminationStatus, outText))
            }
        }
    }

    private func tryDelete(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }
}

/// A tiny thread-safe text accumulator for building the operation log off the main actor.
private final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    func line(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        buffer += s + "\n"
    }

    func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        buffer += s
        if !s.hasSuffix("\n") { buffer += "\n" }
    }
}
