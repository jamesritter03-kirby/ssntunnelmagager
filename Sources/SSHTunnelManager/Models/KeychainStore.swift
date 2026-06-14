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
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    func deletePassword(for id: UUID) {
        SecItemDelete(baseQuery(for: id) as CFDictionary)
    }

    /// Retrieve the password, optionally requiring Touch ID / login-password auth first.
    /// The completion is always called (on an arbitrary queue).
    func password(for id: UUID,
                  requireAuth: Bool,
                  reason: String,
                  completion: @escaping (Result<String, Error>) -> Void) {
        let read: () -> Void = { [weak self] in
            guard let self else { return }
            var query = self.baseQuery(for: id)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnData as String] = true
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                if let data = item as? Data, let password = String(data: data, encoding: .utf8) {
                    completion(.success(password))
                } else {
                    completion(.failure(KeychainError.notFound))
                }
            case errSecItemNotFound:
                completion(.failure(KeychainError.notFound))
            default:
                completion(.failure(KeychainError.unexpected(status)))
            }
        }

        guard requireAuth else { read(); return }

        let context = LAContext()
        var error: NSError?
        // .deviceOwnerAuthentication = Touch ID, falling back to the login password.
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                if success {
                    read()
                } else {
                    completion(.failure(KeychainError.authenticationFailed))
                }
            }
        } else {
            // No biometrics or passcode configured — fall back to reading directly.
            read()
        }
    }
}
