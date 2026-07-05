import Foundation
import Security
import LocalAuthentication

/// Stores SSH passwords in the macOS Keychain, keyed by profile id.
///
/// Reads can be gated behind Touch ID / the login password using
/// `LocalAuthentication`. The secret itself lives in the login keychain with
/// "this device only" accessibility (never synced to iCloud).
///
/// Design note: the biometric check is enforced by the app via `LAContext`,
/// and the item uses the classic file-based keychain. This avoids the
/// Developer-ID / entitlement requirements of Secure-Enclave access-control
/// items, so it works for a locally (ad-hoc) signed build.
final class KeychainStore {
    static let shared = KeychainStore()
    private init() {}

    private let service = "com.local.sshtunnelmanager.passwords"

    enum KeychainError: LocalizedError {
        case authenticationFailed
        case notFound
        case unexpected(OSStatus)

        var errorDescription: String? {
            switch self {
            case .authenticationFailed: return "Authentication was cancelled or failed."
            case .notFound: return "No saved password was found."
            case .unexpected(let status): return "Keychain error (\(status))."
            }
        }
    }

    private func baseQuery(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    /// Whether a password exists for this profile. Reads only metadata, so it
    /// never triggers an authentication prompt.
    func hasPassword(for id: UUID) -> Bool {
        var query = baseQuery(for: id)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = false
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// True if biometrics (Touch ID) are available on this Mac.
    func biometricsAvailable() -> Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Store (or replace) the password for a profile.
    @discardableResult
    func setPassword(_ password: String, for id: UUID) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
        SecItemDelete(baseQuery(for: id) as CFDictionary)   // replace any existing
        var query = baseQuery(for: id)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let ok = SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        invalidateCachedSecret(for: id)
        return ok
    }

    func deletePassword(for id: UUID) {
        SecItemDelete(baseQuery(for: id) as CFDictionary)
        invalidateCachedSecret(for: id)
    }

    /// Synchronously read a stored password **without** any Touch ID prompt. Used
    /// for convenience credentials the app persisted itself — e.g. an ad-hoc tab's
    /// password captured when a workspace is saved as a profile — where the
    /// biometric gate isn't wanted. Returns nil when none is stored.
    func readPassword(for id: UUID) -> String? {
        var query = baseQuery(for: id)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Copy a saved password from one id to another — used when “Save Workspace as
    /// Profile” clones a connection (the clone gets fresh profile / forward ids and
    /// must inherit the source's secrets to authenticate the same way). Reads the
    /// raw item and re-adds it under `newID`; **no Touch ID prompt**, because the
    /// biometric gate is enforced by the app at *use* time, not on the item itself
    /// (see the design note above). No-op when the source has no saved password or
    /// the ids are equal. Returns whether a password was copied.
    @discardableResult
    func copyPassword(from oldID: UUID, to newID: UUID) -> Bool {
        guard oldID != newID, let password = readPassword(for: oldID) else { return false }
        return setPassword(password, for: newID)
    }

    // MARK: - Concurrent-unlock coalescing

    /// A password unlocked via Touch ID, cached briefly so sibling tabs of the
    /// same connection — which reach their password prompts at nearly the same
    /// moment — reuse a single authentication. Without this each tab fires its
    /// own biometric evaluation; macOS shows only one prompt and the rest fail,
    /// which is why (e.g.) an SFTP tab would autofill after Touch ID while the
    /// SSH tab beside it silently dropped to a manual password prompt.
    private struct CachedSecret { let secret: String; let expiry: Date }
    private var secretCache: [UUID: CachedSecret] = [:]
    /// Completions waiting on an in-flight authentication for a given id, so a
    /// second request while a prompt is showing joins it instead of starting a
    /// competing prompt.
    private var pendingAuthWaiters: [UUID: [(Result<String, Error>) -> Void]] = [:]
    /// How long an unlocked secret is reused without re-prompting.
    private let authCacheTTL: TimeInterval = 60

    /// Drop any cached unlock for an id (on password change / removal).
    private func invalidateCachedSecret(for id: UUID) {
        DispatchQueue.main.async { [weak self] in self?.secretCache[id] = nil }
    }

    /// Synchronously read a stored password with **no** auth prompt, as a Result.
    private func rawRead(for id: UUID) -> Result<String, Error> {
        var query = baseQuery(for: id)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            if let data = item as? Data, let password = String(data: data, encoding: .utf8) {
                return .success(password)
            }
            return .failure(KeychainError.notFound)
        case errSecItemNotFound:
            return .failure(KeychainError.notFound)
        default:
            return .failure(KeychainError.unexpected(status))
        }
    }

    /// Retrieve the password, optionally requiring Touch ID / login-password auth
    /// first. When auth is required, concurrent requests for the same id collapse
    /// into a single prompt and a brief cache, so connecting a profile whose
    /// workspace opens several tabs at once only asks for the fingerprint once.
    /// The completion is always called (on the main queue for the auth path).
    func password(for id: UUID,
                  requireAuth: Bool,
                  reason: String,
                  completion: @escaping (Result<String, Error>) -> Void) {
        guard requireAuth else { completion(rawRead(for: id)); return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // A recent unlock for this id? Reuse it — no prompt.
            if let cached = self.secretCache[id], cached.expiry > Date() {
                completion(.success(cached.secret))
                return
            }
            self.secretCache[id] = nil

            // An authentication for this id is already showing — join it rather
            // than racing a second biometric prompt (which the OS would drop).
            if self.pendingAuthWaiters[id] != nil {
                self.pendingAuthWaiters[id]?.append(completion)
                return
            }
            self.pendingAuthWaiters[id] = [completion]

            // Deliver one result to everyone waiting on this id, caching a success.
            let deliver: (Result<String, Error>) -> Void = { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if case .success(let secret) = result {
                        self.secretCache[id] = CachedSecret(
                            secret: secret,
                            expiry: Date().addingTimeInterval(self.authCacheTTL))
                    }
                    let waiters = self.pendingAuthWaiters[id] ?? []
                    self.pendingAuthWaiters[id] = nil
                    for waiter in waiters { waiter(result) }
                }
            }

            let context = LAContext()
            var error: NSError?
            // .deviceOwnerAuthentication = Touch ID, falling back to the login password.
            if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, _ in
                    guard let self else { return }
                    deliver(success ? self.rawRead(for: id) : .failure(KeychainError.authenticationFailed))
                }
            } else {
                // No biometrics or passcode configured — read directly.
                deliver(self.rawRead(for: id))
            }
        }
    }

    // MARK: - Ad-hoc ZeroTier passwords (keyed by username)

    /// ZeroTier "Connect as" credentials aren't tied to a saved profile, so they
    /// live under their own service and are keyed by the username. Reads are
    /// synchronous and never prompt for Touch ID — these are lightweight
    /// convenience passwords for one-off connections, stored "this device only".
    private let zeroTierService = "com.local.sshtunnelmanager.zerotier"

    private func zeroTierQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: zeroTierService,
            kSecAttrAccount as String: account,
        ]
    }

    /// Store (or replace) the password for a ZeroTier "Connect as" username.
    @discardableResult
    func setZeroTierPassword(_ password: String, for account: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
        SecItemDelete(zeroTierQuery(for: account) as CFDictionary)   // replace any existing
        var query = zeroTierQuery(for: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Remove the saved password for a ZeroTier "Connect as" username.
    func deleteZeroTierPassword(for account: String) {
        SecItemDelete(zeroTierQuery(for: account) as CFDictionary)
    }

    /// Fetch the saved password for a ZeroTier "Connect as" username, or nil.
    func zeroTierPassword(for account: String) -> String? {
        var query = zeroTierQuery(for: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
