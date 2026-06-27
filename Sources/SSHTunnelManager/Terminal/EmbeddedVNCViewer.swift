import SwiftUI
import AppKit
import Security
import LocalAuthentication
import RoyalVNCKit

/// Drives an **in-app** VNC session that renders the remote desktop inside the
/// tab (via RoyalVNCKit's `VNCCAFramebufferView`) instead of shelling out to
/// macOS Screen Sharing.app.
///
/// The SSH tunnel itself is still owned by `VNCClient` (`ssh -N -L …`); this
/// object just connects a real VNC client to the local end of that tunnel
/// (`127.0.0.1:localPort`) once it's listening, handles authentication, and
/// vends the live framebuffer `NSView` for SwiftUI to host.
final class EmbeddedVNCViewer: NSObject, ObservableObject, VNCConnectionDelegate {
    enum Status: Equatable {
        case idle
        case connecting
        case authenticating
        case connected
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    /// The live `VNCCAFramebufferView` (an `NSView`) to embed, or `nil` while
    /// connecting / after a disconnect.
    @Published private(set) var framebufferView: NSView?
    /// Whether the remote screen is scaled to fit the tab (vs. shown 1:1).
    @Published private(set) var isScalingEnabled: Bool

    private let host: String
    private let port: UInt16
    private let profileID: UUID?
    private let defaultUsername: String
    private let serverLabel: String
    /// Whether reading a remembered Keychain password should require Touch ID /
    /// the login password first (mirrors the profile's SSH-password setting).
    private let requireBiometricAuth: Bool
    /// A password supplied up front (e.g. from the ad-hoc “New VNC Connection”
    /// sheet) to try once before prompting. Cleared after the first use.
    private var presetPassword: String?

    /// The live connection (strong ref required — the SDK keeps `delegate` weak).
    private var connection: VNCConnection?
    /// True once we've shown at least one frame (i.e. auth succeeded).
    private var didReachFramebuffer = false
    /// Set when we silently reused a saved Keychain credential (no prompt); used
    /// to invalidate a bad saved password if the connection then fails on auth.
    private var usedSavedCredentialWithoutPrompt = false
    /// Cached for seamless reconnects (e.g. toggling scaling) without re-prompting.
    private var inMemoryCredential: (any VNCCredential)?

    init(host: String, port: Int, profileID: UUID?,
         defaultUsername: String, serverLabel: String,
         presetPassword: String? = nil, requireBiometricAuth: Bool = false,
         scaling: Bool = true) {
        self.host = host
        self.port = UInt16(max(0, min(port, 65535)))
        self.profileID = profileID
        self.defaultUsername = defaultUsername
        self.serverLabel = serverLabel
        self.requireBiometricAuth = requireBiometricAuth
        self.presetPassword = presetPassword
        self.isScalingEnabled = scaling
        super.init()
    }

    deinit {
        connection?.delegate = nil
        connection?.disconnect()
    }

    /// The `vnc://` URL macOS Screen Sharing opens for this same endpoint — used
    /// by the “Open in Screen Sharing” fallback button.
    var externalURL: URL? { URL(string: "vnc://\(host):\(port)") }

    /// Hand the connection off to macOS Screen Sharing.app.
    func openExternal() {
        guard let url = externalURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Lifecycle

    /// Connect to the local end of the SSH tunnel. Safe to call repeatedly; it
    /// no-ops while a connection already exists.
    func connect() {
        guard connection == nil, port > 0 else { return }
        startConnection()
    }

    /// Disconnect the VNC view (the SSH tunnel stays up).
    func disconnect() {
        connection?.disconnect()
    }

    /// Switch between fit-to-window and 1:1. Because `Settings` is immutable, this
    /// reconnects with the new value, reusing the cached credential so there's no
    /// re-prompt.
    func setScaling(_ enabled: Bool) {
        guard enabled != isScalingEnabled else { return }
        isScalingEnabled = enabled
        guard let old = connection else { return }
        old.delegate = nil
        old.disconnect()
        connection = nil
        framebufferView = nil
        status = .connecting
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.startConnection()
        }
    }

    private func startConnection() {
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: host,
            port: port,
            isShared: true,
            isScalingEnabled: isScalingEnabled,
            useDisplayLink: false,
            inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
            isClipboardRedirectionEnabled: true,
            colorDepth: .depth24Bit,
            frameEncodings: .default
        )
        let conn = VNCConnection(settings: settings)
        conn.delegate = self
        connection = conn
        didReachFramebuffer = false
        onMain { self.status = .connecting }
        conn.connect()
    }

    // MARK: - VNCConnectionDelegate

    func connection(_ connection: VNCConnection,
                    stateDidChange connectionState: VNCConnection.ConnectionState) {
        switch connectionState.status {
        case .connecting:
            onMain { if self.status != .authenticating { self.status = .connecting } }
        case .connected:
            // The framebuffer view (and `.connected` status) is set in
            // didCreateFramebuffer once we have something to draw.
            break
        case .disconnecting:
            break
        case .disconnected:
            handleDisconnect(error: connectionState.error)
        @unknown default:
            break
        }
    }

    func connection(_ connection: VNCConnection,
                    credentialFor authenticationType: VNCAuthenticationType,
                    completion: @escaping ((any VNCCredential)?) -> Void) {
        // 1. Reuse an in-memory credential for seamless reconnects.
        if let cached = inMemoryCredential {
            completion(cached)
            return
        }
        // 2. Try a remembered credential from the Keychain. If the profile
        //    requires it, unlock with Touch ID / the login password first. This
        //    runs asynchronously, so fall through to the preset / prompt only if
        //    nothing usable comes back (no saved password, or auth was declined).
        if let pid = profileID, VNCCredentialStore.hasPassword(for: pid) {
            let reason = "unlock the saved Screen Sharing password for \(serverLabel)"
            VNCCredentialStore.credential(for: pid,
                                          authenticationType: authenticationType,
                                          defaultUsername: defaultUsername,
                                          requireAuth: requireBiometricAuth,
                                          reason: reason) { [weak self] saved in
                guard let self else { completion(nil); return }
                if let saved {
                    self.inMemoryCredential = saved
                    self.usedSavedCredentialWithoutPrompt = true
                    completion(saved)
                } else {
                    self.provideFallbackCredential(authenticationType: authenticationType,
                                                   completion: completion)
                }
            }
            return
        }
        provideFallbackCredential(authenticationType: authenticationType, completion: completion)
    }

    /// No usable saved credential — try a password supplied up front (the ad-hoc
    /// dialog) once, otherwise ask the user.
    private func provideFallbackCredential(authenticationType: VNCAuthenticationType,
                                           completion: @escaping ((any VNCCredential)?) -> Void) {
        // Use a password supplied up front (ad-hoc dialog) before prompting.
        // Try it only once — if it's wrong, the reconnect should prompt.
        if let preset = presetPassword, !preset.isEmpty {
            presetPassword = nil
            let cred = makeCredential(password: preset, authenticationType: authenticationType)
            inMemoryCredential = cred
            usedSavedCredentialWithoutPrompt = true
            completion(cred)
            return
        }
        // Otherwise ask the user (on the main thread).
        DispatchQueue.main.async { [weak self] in
            guard let self else { completion(nil); return }
            self.status = .authenticating
            let credential = self.promptForCredential(authenticationType: authenticationType)
            if let credential { self.inMemoryCredential = credential }
            completion(credential)
        }
    }

    private func makeCredential(password: String,
                               authenticationType: VNCAuthenticationType) -> any VNCCredential {
        if authenticationType.requiresUsername {
            return VNCUsernamePasswordCredential(username: defaultUsername, password: password)
        }
        return VNCPasswordCredential(password: password)
    }

    func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        makeFramebufferView(connection: connection, framebuffer: framebuffer)
    }

    func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
        makeFramebufferView(connection: connection, framebuffer: framebuffer)
    }

    // Consumed by the framebuffer view; required by the protocol.
    func connection(_ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer,
                    x: UInt16, y: UInt16, width: UInt16, height: UInt16) {}
    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {}

    // MARK: - Framebuffer view

    private func makeFramebufferView(connection: VNCConnection, framebuffer: VNCFramebuffer) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection === connection else { return }
            let size = framebuffer.cgSize
            let frame = NSRect(x: 0, y: 0,
                               width: max(size.width, 1), height: max(size.height, 1))
            let view = VNCCAFramebufferView(frame: frame,
                                            framebuffer: framebuffer,
                                            connection: connection,
                                            connectionDelegate: self)
            self.didReachFramebuffer = true
            self.usedSavedCredentialWithoutPrompt = false
            self.framebufferView = view
            self.status = .connected
        }
    }

    // MARK: - Disconnect handling

    private func handleDisconnect(error: Error?) {
        let failedOnSavedCredential = usedSavedCredentialWithoutPrompt && !didReachFramebuffer
        if failedOnSavedCredential, error != nil, let pid = profileID {
            // A remembered password that never produced a frame is probably wrong.
            VNCCredentialStore.clear(for: pid)
            inMemoryCredential = nil
        }
        onMain {
            self.connection = nil
            self.framebufferView = nil
            if let error {
                self.status = .failed((error as NSError).localizedDescription)
            } else {
                self.status = .idle
            }
        }
    }

    // MARK: - Credential prompt

    private func promptForCredential(authenticationType: VNCAuthenticationType) -> (any VNCCredential)? {
        let needsUsername = authenticationType.requiresUsername
        let fieldWidth: CGFloat = 260, rowH: CGFloat = 24, gap: CGFloat = 8
        let rows = needsUsername ? 3 : 2
        let height = CGFloat(rows) * rowH + CGFloat(rows - 1) * gap
        let container = NSView(frame: NSRect(x: 0, y: 0, width: fieldWidth, height: height))

        let passwordField = NSSecureTextField(frame: .zero)
        passwordField.placeholderString = "Password"
        let usernameField = NSTextField(frame: .zero)
        usernameField.placeholderString = "Username"
        usernameField.stringValue = defaultUsername
        let remember = NSButton(checkboxWithTitle: "Remember password", target: nil, action: nil)
        remember.state = .on

        var topY = height - rowH
        if needsUsername {
            usernameField.frame = NSRect(x: 0, y: topY, width: fieldWidth, height: rowH)
            container.addSubview(usernameField)
            topY -= (rowH + gap)
        }
        passwordField.frame = NSRect(x: 0, y: topY, width: fieldWidth, height: rowH)
        container.addSubview(passwordField)
        remember.frame = NSRect(x: 0, y: 0, width: fieldWidth, height: rowH)
        container.addSubview(remember)

        let alert = NSAlert()
        alert.messageText = needsUsername ? "Sign in to \(serverLabel)" : "Screen Sharing password"
        alert.informativeText = needsUsername
            ? "Enter the account name and password to control \(serverLabel)."
            : "Enter the Screen Sharing (VNC) password for \(serverLabel)."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = container
        alert.window.initialFirstResponder = needsUsername ? usernameField : passwordField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let pw = passwordField.stringValue
        let credential: any VNCCredential = needsUsername
            ? VNCUsernamePasswordCredential(username: usernameField.stringValue, password: pw)
            : VNCPasswordCredential(password: pw)
        if remember.state == .on, let pid = profileID {
            VNCCredentialStore.save(credential, for: pid)
        }
        return credential
    }

    // MARK: - Helpers

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

// MARK: - Keychain store for VNC credentials

/// Stores Screen Sharing (VNC) passwords separately from SSH passwords so the
/// two never collide. Keyed by profile id, "this device only", never synced.
enum VNCCredentialStore {
    private static let pwService = "com.local.sshtunnelmanager.vnc.password"
    private static let userService = "com.local.sshtunnelmanager.vnc.username"

    static func save(_ credential: any VNCCredential, for id: UUID) {
        if let up = credential as? VNCUsernamePasswordCredential {
            setItem(up.password, service: pwService, account: id.uuidString)
            setItem(up.username, service: userService, account: id.uuidString)
        } else if let p = credential as? VNCPasswordCredential {
            setItem(p.password, service: pwService, account: id.uuidString)
            deleteItem(service: userService, account: id.uuidString)
        }
    }

    static func credential(for id: UUID, authenticationType: VNCAuthenticationType,
                           defaultUsername: String) -> (any VNCCredential)? {
        guard let pw = getItem(service: pwService, account: id.uuidString), !pw.isEmpty else { return nil }
        if authenticationType.requiresUsername {
            let user = getItem(service: userService, account: id.uuidString) ?? defaultUsername
            guard !user.isEmpty else { return nil }
            return VNCUsernamePasswordCredential(username: user, password: pw)
        }
        if authenticationType.requiresPassword {
            return VNCPasswordCredential(password: pw)
        }
        return nil
    }

    /// Whether a remembered password exists for this profile. Reads only
    /// metadata, so it never triggers a Touch ID / Keychain prompt.
    static func hasPassword(for id: UUID) -> Bool {
        var q = base(pwService, id.uuidString)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnData as String] = false
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    /// Retrieve a remembered credential, optionally requiring Touch ID / the
    /// login password first. The completion is always called (on an arbitrary
    /// queue); `nil` means no usable credential (or the user declined auth).
    static func credential(for id: UUID, authenticationType: VNCAuthenticationType,
                           defaultUsername: String, requireAuth: Bool, reason: String,
                           completion: @escaping ((any VNCCredential)?) -> Void) {
        let read: () -> Void = {
            completion(credential(for: id, authenticationType: authenticationType,
                                  defaultUsername: defaultUsername))
        }
        guard requireAuth else { read(); return }
        let context = LAContext()
        var error: NSError?
        // .deviceOwnerAuthentication = Touch ID, falling back to the login password.
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                if success { read() } else { completion(nil) }
            }
        } else {
            // No biometrics or passcode configured — read directly.
            read()
        }
    }

    static func clear(for id: UUID) {
        deleteItem(service: pwService, account: id.uuidString)
        deleteItem(service: userService, account: id.uuidString)
    }

    private static func base(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func setItem(_ value: String, service: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        SecItemDelete(base(service, account) as CFDictionary)
        var q = base(service, account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    private static func getItem(service: String, account: String) -> String? {
        var q = base(service, account)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteItem(service: String, account: String) {
        SecItemDelete(base(service, account) as CFDictionary)
    }
}

// MARK: - SwiftUI host for the framebuffer NSView

/// Hosts the live `VNCCAFramebufferView` inside SwiftUI. The view is created
/// asynchronously by `EmbeddedVNCViewer` (in a delegate callback), so this just
/// swaps it into a black container whenever it changes.
struct VNCFramebufferHostView: NSViewRepresentable {
    let framebufferView: NSView?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if container.subviews.first === framebufferView { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let fb = framebufferView else { return }
        fb.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(fb)
        NSLayoutConstraint.activate([
            fb.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fb.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fb.topAnchor.constraint(equalTo: container.topAnchor),
            fb.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        // Give the remote screen keyboard focus so typing is forwarded.
        DispatchQueue.main.async { fb.window?.makeFirstResponder(fb) }
    }
}
