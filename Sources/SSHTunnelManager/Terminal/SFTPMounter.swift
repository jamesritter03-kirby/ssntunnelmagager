import Foundation
import AppKit

/// Mounts a profile's remote filesystem locally via `sshfs` (FUSE), so an SFTP
/// connection can be opened in Finder and used by any app as an ordinary folder.
///
/// Unlike `ssh` / `sftp` — which ship with macOS — there is no built-in FUSE
/// layer, so mounting relies on a helper the user installs once. The recommended
/// helper is **fuse-t** (kernel-extension-free, no reboot) together with
/// **sshfs**; macFUSE + sshfs works too. When the helper is missing we surface a
/// short guided-install explainer (`SFTPMountHelpSheet`) instead of failing
/// silently.
///
/// The mount is an *independent* ssh connection (sshfs opens its own), so it does
/// not depend on the interactive `SFTPClient` browser being connected. It reuses
/// the same profile inputs `SFTPCommandBuilder` uses — host, port, identity file
/// and jump host — translated into sshfs `-o` options, and the machine's existing
/// `~/.ssh/known_hosts` (adding an unknown host automatically, since the browser
/// already trusts it).
final class SFTPMounter: ObservableObject {
    enum State: Equatable {
        case unmounted
        case mounting
        case mounted(URL)
        case unmounting
        case failed(String)

        var isMounted: Bool { if case .mounted = self { return true } else { return false } }
    }

    @Published private(set) var state: State = .unmounted

    /// The profile this mounter targets. Resolved fresh from the store at mount
    /// time so edits to host / credentials are picked up. `nil` for ad-hoc SFTP
    /// tabs (no saved profile), which can't be mounted.
    private let profileID: UUID?

    init(profileID: UUID?) {
        self.profileID = profileID
    }

    // MARK: - Derived state

    var isMounted: Bool { state.isMounted }
    var isBusy: Bool { state == .mounting || state == .unmounting }
    var mountPoint: URL? { if case .mounted(let url) = state { return url } else { return nil } }
    /// Whether a saved profile backs this session (ad-hoc SFTP tabs can't mount).
    var canMount: Bool { profileID != nil }
    var failureMessage: String? { if case .failed(let m) = state { return m } else { return nil } }

    /// Clear a `.failed` state back to idle (after the user dismisses the error).
    func clearFailure() { if case .failed = state { state = .unmounted } }

    // MARK: - Helper discovery

    /// Directories a Homebrew / manual `sshfs` install commonly lives in. A GUI
    /// app launched from Finder inherits a minimal PATH, so we probe explicit
    /// locations rather than relying on `which`.
    private static let searchDirs = [
        "/opt/homebrew/bin", "/usr/local/bin",
        "/opt/homebrew/sbin", "/usr/local/sbin",
        "/usr/bin", "/bin",
    ]

    /// The path to an installed `sshfs`, or `nil` if none is found.
    static var sshfsPath: String? { locate("sshfs") }
    /// Whether a usable FUSE mount helper is installed.
    static var helperInstalled: Bool { sshfsPath != nil }

    private static func locate(_ tool: String) -> String? {
        let fm = FileManager.default
        for dir in searchDirs {
            let path = dir + "/" + tool
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    // MARK: - Mount

    /// Mount the profile's remote home directory locally and (optionally) reveal
    /// it in Finder. No-ops if already mounted or busy.
    func mount(reveal: Bool = true) {
        guard !isBusy, !isMounted else { return }
        guard let profileID,
              let profile = ProfileStore.shared.profiles.first(where: { $0.id == profileID }) else {
            state = .failed("This SFTP tab isn’t backed by a saved profile, so it can’t be mounted.")
            return
        }
        guard let sshfs = Self.sshfsPath else {
            state = .failed("No FUSE mount helper is installed.")
            return
        }
        state = .mounting

        // When the profile authenticates with a saved password, fetch it up front
        // (this may prompt for Touch ID) and pipe it to sshfs; key-based profiles
        // skip this and let ssh / the agent handle auth.
        if KeychainStore.shared.hasPassword(for: profile.id) {
            KeychainStore.shared.password(
                for: profile.id,
                requireAuth: profile.requireAuthForSavedPassword,
                reason: "mount “\(profile.name)” as a drive"
            ) { [weak self] result in
                switch result {
                case .success(let password):
                    DispatchQueue.main.async {
                        self?.launchMount(sshfs: sshfs, profile: profile,
                                          password: password, reveal: reveal)
                    }
                case .failure:
                    DispatchQueue.main.async {
                        self?.state = .failed("Couldn’t read the saved password (authentication was cancelled or failed).")
                    }
                }
            }
        } else {
            launchMount(sshfs: sshfs, profile: profile, password: nil, reveal: reveal)
        }
    }

    private func launchMount(sshfs: String, profile: SSHProfile, password: String?, reveal: Bool) {
        let point = Self.mountPoint(for: profile)
        // sshfs needs an existing, empty directory to mount onto.
        try? FileManager.default.createDirectory(at: point, withIntermediateDirectories: true)

        let args = Self.arguments(for: profile, mountPoint: point.path,
                                  usePasswordStdin: password != nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: sshfs)
            proc.arguments = args
            let stdin = Pipe(), stderr = Pipe()
            proc.standardInput = stdin
            proc.standardError = stderr
            proc.standardOutput = Pipe()
            // sshfs shells out to `ssh` and the FUSE mount helpers — make sure the
            // usual Homebrew / system tool dirs are on PATH (a Finder-launched GUI
            // app inherits only a minimal one).
            var env = ProcessInfo.processInfo.environment
            let toolDirs = ["/opt/homebrew/bin", "/usr/local/bin",
                            "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            env["PATH"] = (toolDirs + [env["PATH"] ?? ""]).joined(separator: ":")
            proc.environment = env

            do {
                try proc.run()
            } catch {
                self?.finishMount(success: false, point: point,
                                  message: error.localizedDescription, reveal: reveal)
                return
            }
            if let password {
                stdin.fileHandleForWriting.write(Data((password + "\n").utf8))
            }
            try? stdin.fileHandleForWriting.close()
            proc.waitUntilExit()

            let errText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                                 as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            // sshfs daemonizes once the mount is established, so a 0 exit status
            // means success; anything else is a mount failure.
            let ok = proc.terminationStatus == 0
            let message = ok ? "" : (errText.isEmpty
                ? "sshfs exited with status \(proc.terminationStatus)."
                : errText)
            self?.finishMount(success: ok, point: point, message: message, reveal: reveal)
        }
    }

    private func finishMount(success: Bool, point: URL, message: String, reveal: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if success {
                self.state = .mounted(point)
                if reveal { NSWorkspace.shared.open(point) }
            } else {
                // Remove the empty mount-point dir we created so it doesn't linger.
                try? FileManager.default.removeItem(at: point)
                self.state = .failed(Self.friendlyError(message))
            }
        }
    }

    // MARK: - Unmount

    /// Unmount and clean up, updating published state. Used by the toolbar / menu.
    func unmount() {
        guard case .mounted(let point) = state else { return }
        state = .unmounting
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Self.runUnmount(point)
            DispatchQueue.main.async {
                try? FileManager.default.removeItem(at: point)
                self?.state = .unmounted
            }
        }
    }

    /// Best-effort fire-and-forget unmount used when the tab closes or the app
    /// quits, so a mount doesn't outlive its SFTP session.
    func unmountQuietly() {
        guard case .mounted(let point) = state else { return }
        state = .unmounted
        DispatchQueue.global(qos: .userInitiated).async {
            Self.runUnmount(point)
            try? FileManager.default.removeItem(at: point)
        }
    }

    private static func runUnmount(_ point: URL) {
        // `umount` handles the common case; `diskutil unmount force` is the
        // fallback for a busy fuse-t (NFS-backed) volume.
        if run("/sbin/umount", [point.path]) == 0 { return }
        _ = run("/usr/sbin/diskutil", ["unmount", "force", point.path])
    }

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> Int32 {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return -1 }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run() } catch { return -1 }
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    // MARK: - Command building

    /// The local mount-point directory for a profile: `~/mnt/<sanitized name>`.
    static func mountPoint(for profile: SSHProfile) -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("mnt", isDirectory: true)
        let name = sanitized(profile.name.isEmpty ? profile.host : profile.name)
        return base.appendingPathComponent(name.isEmpty ? "sftp" : name, isDirectory: true)
    }

    private static func sanitized(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters)
        return name.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Build the `sshfs` argument list from a profile. The remote path is left
    /// empty (`host:`) so it mounts the remote **home** directory. Reuses the
    /// same host / port / identity / jump-host inputs as `SFTPCommandBuilder`,
    /// translated into sshfs `-o` options.
    static func arguments(for profile: SSHProfile, mountPoint: String,
                          usePasswordStdin: Bool) -> [String] {
        let host = profile.host.trimmingCharacters(in: .whitespaces)
        let user = profile.username.trimmingCharacters(in: .whitespaces)
        // A trailing colon with no path mounts the remote home directory.
        let dest = (user.isEmpty ? host : "\(user)@\(host)") + ":"

        var args = [dest, mountPoint]

        if let port = Int(profile.port.trimmingCharacters(in: .whitespaces)), port != 22 {
            args += ["-o", "Port=\(port)"]
        }
        let identity = profile.identityFile.trimmingCharacters(in: .whitespaces)
        if !identity.isEmpty {
            args += ["-o", "IdentityFile=\(SSHCommandBuilder.expandPath(identity))"]
        }
        let jump = profile.jumpHost.trimmingCharacters(in: .whitespaces)
        if !jump.isEmpty {
            args += ["-o", "ProxyJump=\(jump)"]
        }
        if profile.compression { args += ["-o", "Compression=yes"] }
        if usePasswordStdin { args += ["-o", "password_stdin"] }

        // Reuse the already-trusted known_hosts (accept a new host automatically),
        // keep the link alive, auto-reconnect, and give Finder a friendly name.
        args += [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "reconnect",
            "-o", "volname=\(profile.name.isEmpty ? host : profile.name)",
        ]
        return args
    }

    /// Turn a raw sshfs / FUSE error into something friendlier for the alert.
    private static func friendlyError(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("no fuse") || lower.contains("fuse device not found")
            || (lower.contains("fuse") && lower.contains("load")) {
            return "The FUSE helper isn’t fully set up. Finish installing fuse-t (and allow it in System Settings ▸ Privacy & Security), then try again.\n\n\(raw)"
        }
        if lower.contains("permission denied") || lower.contains("authentication") {
            return "Authentication failed. Check the profile’s credentials, then try again.\n\n\(raw)"
        }
        if lower.contains("not a directory") || lower.contains("mountpoint") {
            return "The mount point couldn’t be prepared. Make sure ~/mnt is writable, then try again.\n\n\(raw)"
        }
        return raw.isEmpty ? "The mount failed for an unknown reason." : raw
    }
}
