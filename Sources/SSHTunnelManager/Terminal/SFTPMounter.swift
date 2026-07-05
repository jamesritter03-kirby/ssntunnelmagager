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

    /// Set once an automatic remount has been attempted for this session, so a
    /// remembered mount is re-established at most once (even as the tab's view
    /// appears and disappears on workspace switches).
    private var didAttemptAutoMount = false

    /// The profile this mounter targets. Resolved fresh from the store at mount
    /// time so edits to host / credentials are picked up. `nil` for ad-hoc SFTP
    /// tabs (no saved profile), which mount via `adHocProfile` instead.
    private let profileID: UUID?

    /// For an **ad-hoc** (profile-free) SFTP tab: a synthetic profile built from
    /// the tab's captured host / port / username, plus the password to mount with.
    /// That password is either held in memory (typed into the “New SFTP
    /// Connection” sheet) or persisted under a Keychain id (a tab rebuilt from a
    /// workspace saved as a profile). Either lets an ad-hoc tab mount even though
    /// it has no saved profile; both nil = key auth only.
    private let adHocProfile: SSHProfile?
    private let adHocPasswordID: UUID?
    private let adHocInMemoryPassword: String?

    init(profileID: UUID?) {
        self.profileID = profileID
        self.adHocProfile = nil
        self.adHocPasswordID = nil
        self.adHocInMemoryPassword = nil
    }

    /// Ad-hoc mount target: host / port / username typed for a profile-free tab.
    /// The password may be supplied in memory (`password`) and/or persisted under
    /// `credentialID`; nil for both means key-based auth only.
    init(adHocHost host: String, port: Int, username: String,
         password: String? = nil, credentialID: UUID?) {
        self.profileID = nil
        self.adHocPasswordID = credentialID
        self.adHocInMemoryPassword = password
        let clean = host.trimmingCharacters(in: .whitespaces)
        if clean.isEmpty {
            self.adHocProfile = nil
        } else {
            var p = SSHProfile()
            p.host = clean
            p.port = String(port)
            p.username = username.trimmingCharacters(in: .whitespaces)
            p.name = p.username.isEmpty ? clean : "\(p.username)@\(clean)"
            self.adHocProfile = p
        }
    }

    // MARK: - Derived state

    var isMounted: Bool { state.isMounted }
    var isBusy: Bool { state == .mounting || state == .unmounting }
    var mountPoint: URL? { if case .mounted(let url) = state { return url } else { return nil } }
    /// Whether a saved profile (or an ad-hoc tab's captured details) backs this
    /// session, so it can be mounted.
    var canMount: Bool { profileID != nil || adHocProfile != nil }
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
    func mount(reveal: Bool = true, announceFailure: Bool = true) {
        guard !isBusy, !isMounted else { return }
        // Resolve the connection to mount: a saved profile (looked up fresh so
        // credential edits are picked up) or an ad-hoc tab's captured details.
        let profile: SSHProfile
        let isAdHoc: Bool
        if let profileID,
           let p = ProfileStore.shared.profiles.first(where: { $0.id == profileID }) {
            profile = p
            isAdHoc = false
        } else if let p = adHocProfile {
            profile = p
            isAdHoc = true
        } else {
            state = .failed("This SFTP tab isn’t backed by a saved profile, so it can’t be mounted.")
            return
        }
        guard let sshfs = Self.sshfsPath else {
            state = .failed("No FUSE mount helper is installed.")
            return
        }
        state = .mounting

        // Ad-hoc tab: mount with its persisted password (read directly, no Touch
        // ID gate — matching how it was captured) or the one typed this session;
        // otherwise key auth.
        if isAdHoc {
            let stored = adHocPasswordID.flatMap { KeychainStore.shared.readPassword(for: $0) }
            let password = (stored?.isEmpty == false) ? stored
                : (adHocInMemoryPassword?.isEmpty == false ? adHocInMemoryPassword : nil)
            launchMount(sshfs: sshfs, profile: profile, password: password, reveal: reveal,
                        announceFailure: announceFailure)
            return
        }

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
                                          password: password, reveal: reveal,
                                          announceFailure: announceFailure)
                    }
                case .failure:
                    DispatchQueue.main.async {
                        // Quiet for an automatic remount — a declined Touch ID prompt
                        // shouldn't pop an error every time you reconnect.
                        self?.state = announceFailure
                            ? .failed("Couldn’t read the saved password (authentication was cancelled or failed).")
                            : .unmounted
                    }
                }
            }
        } else {
            launchMount(sshfs: sshfs, profile: profile, password: nil, reveal: reveal,
                        announceFailure: announceFailure)
        }
    }

    private func launchMount(sshfs: String, profile: SSHProfile, password: String?, reveal: Bool,
                             announceFailure: Bool) {
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
                                  message: error.localizedDescription, reveal: reveal,
                                  announceFailure: announceFailure)
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
            self?.finishMount(success: ok, point: point, message: message, reveal: reveal,
                              announceFailure: announceFailure)
        }
    }

    private func finishMount(success: Bool, point: URL, message: String, reveal: Bool,
                             announceFailure: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if success {
                self.state = .mounted(point)
                // Remember this connection so it remounts automatically next time.
                Self.remember(self.rememberKey)
                if reveal { NSWorkspace.shared.open(point) }
            } else {
                // Remove the empty mount-point dir we created so it doesn't linger.
                try? FileManager.default.removeItem(at: point)
                // Surface the failure for a user-initiated mount; stay quiet for an
                // automatic remount so a remembered mount never nags on reconnect.
                self.state = announceFailure ? .failed(Self.friendlyError(message)) : .unmounted
            }
        }
    }

    // MARK: - Unmount

    /// Unmount and clean up, updating published state. Used by the toolbar / menu.
    /// An explicit unmount also **forgets** the remembered auto-mount, so choosing
    /// to eject stops it remounting automatically next time.
    func unmount() {
        guard case .mounted(let point) = state else { return }
        Self.forget(rememberKey)
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

    // MARK: - Remembered mounts

    /// Re-establish a **remembered** mount automatically. Once the user has mounted
    /// this connection (and not since unmounted it), opening the SFTP tab again —
    /// on reconnect or after relaunching the app — mounts it once more without them
    /// asking. Runs at most once per session, and stays silent when the FUSE
    /// helper is missing or auth is declined, so a remembered mount never nags.
    /// Finder isn't force-revealed for an automatic mount.
    func autoMountIfRemembered() {
        guard !didAttemptAutoMount else { return }
        didAttemptAutoMount = true
        guard canMount, !isMounted, !isBusy,
              Self.helperInstalled, Self.isRemembered(rememberKey) else { return }
        mount(reveal: false, announceFailure: false)
    }

    /// A stable key identifying this mount target across sessions: the profile id
    /// for a saved profile, or `user@host:port` for an ad-hoc connection.
    private var rememberKey: String? {
        if let profileID { return "profile:\(profileID.uuidString)" }
        if let p = adHocProfile {
            let user = p.username.isEmpty ? "" : "\(p.username)@"
            return "adhoc:\(user)\(p.host):\(p.port)"
        }
        return nil
    }

    private static let rememberedMountsKey = "autoMountTargets.v1"

    private static func rememberedKeys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: rememberedMountsKey) ?? [])
    }
    private static func setRememberedKeys(_ keys: Set<String>) {
        UserDefaults.standard.set(Array(keys), forKey: rememberedMountsKey)
    }
    /// Whether `key` is a remembered auto-mount target.
    static func isRemembered(_ key: String?) -> Bool {
        guard let key else { return false }
        return rememberedKeys().contains(key)
    }
    /// Record `key` so its connection remounts automatically next time.
    static func remember(_ key: String?) {
        guard let key else { return }
        var keys = rememberedKeys()
        keys.insert(key)
        setRememberedKeys(keys)
    }
    /// Drop `key` from the remembered set (the user unmounted deliberately).
    static func forget(_ key: String?) {
        guard let key else { return }
        var keys = rememberedKeys()
        keys.remove(key)
        setRememberedKeys(keys)
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
