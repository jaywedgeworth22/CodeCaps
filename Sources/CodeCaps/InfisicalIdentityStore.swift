import Foundation
import Security

/// The owner-provisioned Infisical universal-auth identity that lets this Mac
/// act as an Infisical client (see INFISICAL.md).
///
/// A shipped Mac app cannot safely embed a client secret — anyone can extract
/// it from the binary — so there is no fallback identity and no default.
/// The owner pastes his own machine identity's client ID and secret once,
/// under Settings → Infisical Sync, and they live in his Keychain from then
/// on, exactly like the read and ingest tokens `TokenStore` already keeps.
/// `InfisicalSettings` itself only ever holds them in memory.
///
/// Every Keychain call goes through `calls`, so tests inject a fake and never
/// touch the real Keychain.  Values are never logged anywhere on this path.
enum InfisicalIdentityStore {
    struct Identity: Equatable, Sendable {
        var clientId: String
        var clientSecret: String
    }

    /// Test seam: the live implementation shells out to the Security
    /// framework; tests replace the whole struct with an in-memory fake.
    /// The closures are plain (non-`@Sendable`) function types on purpose, so
    /// test fakes can capture their fixtures without Sendable checking noise.
    struct KeychainCalls {
        var read: (_ service: String, _ account: String) -> String?
        var save: (_ service: String, _ account: String, _ value: String) throws -> Void
        var delete: (_ service: String, _ account: String) throws -> Void

        static let live = KeychainCalls(
            read: { SecItem.read(service: $0, account: $1) },
            save: { try SecItem.save(service: $0, account: $1, value: $2) },
            delete: { try SecItem.delete(service: $0, account: $1) }
        )
    }

    static var calls = KeychainCalls.live

    enum StoreError: Error, LocalizedError {
        case keychain(status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                return "The Keychain refused the Infisical identity (OSStatus \(status))."
            }
        }
    }

    /// This build's Keychain service, derived from its bundle identifier the
    /// same way `TokenStore` scopes its own items: a `.dev` build keeps its
    /// own identity and can never overwrite or forget the owner's.
    static func serviceName(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = trimmed.isEmpty ? TokenStore.defaultBundleIdentifier : trimmed
        return base + ".infisical-identity"
    }

    private static let clientIdAccount = "client-id"
    private static let clientSecretAccount = "client-secret"

    /// The provisioned identity, or nil when the owner has not set one up.
    /// A half-written identity (one half missing) reads as absent.
    static func load(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Identity? {
        let service = serviceName(bundleIdentifier: bundleIdentifier)
        guard let clientId = calls.read(service, clientIdAccount),
              !clientId.isEmpty,
              let clientSecret = calls.read(service, clientSecretAccount),
              !clientSecret.isEmpty else { return nil }
        return Identity(clientId: clientId, clientSecret: clientSecret)
    }

    static func save(
        _ identity: Identity,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws {
        let service = serviceName(bundleIdentifier: bundleIdentifier)
        try calls.save(service, clientIdAccount, identity.clientId)
        try calls.save(service, clientSecretAccount, identity.clientSecret)
    }

    static func delete(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws {
        let service = serviceName(bundleIdentifier: bundleIdentifier)
        try calls.delete(service, clientIdAccount)
        try calls.delete(service, clientSecretAccount)
    }
}

extension Notification.Name {
    /// Posted (on the main thread) after the owner saves or forgets the
    /// Infisical client identity, so the app delegate can (re)start the
    /// background refresh cycle without a relaunch.
    static let infisicalIdentityChanged = Notification.Name("CodeCapsInfisicalIdentityChanged")
}

// MARK: - Security framework calls

private enum SecItem {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(service: String, account: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw InfisicalIdentityStore.StoreError.keychain(status: errSecParam)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            // This Mac only: the identity never leaves the Keychain.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw InfisicalIdentityStore.StoreError.keychain(status: status)
        }
    }

    static func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw InfisicalIdentityStore.StoreError.keychain(status: status)
        }
    }
}
