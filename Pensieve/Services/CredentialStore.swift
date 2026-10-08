import Foundation
import Security

/// How a git credential for a remote host is stored/retrieved. `KeychainCredentialStore` is the
/// production adapter (macOS Keychain); `InMemoryCredentialStore` backs tests so no test touches the
/// real login keychain. Callers reserve purpose-specific slots by suffixing the host with `#<purpose>`
/// (for example, `github.com#install`) instead of sharing a host's sync credential. (PLAN-08 / 08.2,
/// PLAN-19 / 19.6)
protocol CredentialStoreProtocol {
    func store(token: String, username: String, forHost host: String) throws
    func credential(forHost host: String) -> GitCredential?
    func delete(forHost host: String) throws
}

enum CredentialHost {
    static let githubInstall = installNamespace(for: "github.com")

    static func installNamespace(for host: String) -> String {
        host + "#install"
    }
}

enum CredentialError: LocalizedError, Equatable {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .keychain(status):
            return "Keychain operation failed (OSStatus \(status))"
        }
    }
}

/// Stores a Personal Access Token in a PENSIEVE-NAMESPACED `kSecClassGenericPassword` item. The
/// production form is `kSecAttrService = "com.jaredatch.Pensieve.git.<host>"`; Debug builds append
/// `.debug` to the bundle identifier. NOT the broad internet-password class keyed by `kSecAttrServer` —
/// that class's `SecItemDelete` could wipe the user's OTHER saved passwords for the same host (e.g. a
/// Safari-saved github.com login). Every store/read/delete is scoped to our service string, so it can
/// never match or touch a foreign credential. Store is a delete-then-add idempotent replace. (§E)
struct KeychainCredentialStore: CredentialStoreProtocol {
    /// Production items are keyed `com.jaredatch.Pensieve.git.<host>` — byte-identical to every item
    /// stored since PLAN-08, so nothing a user saved is orphaned. A Debug build's identifier carries the
    /// `.debug` suffix (project.yml), so its items live under a different service string and can
    /// never read or replace a production credential. A missing identifier (a bare executable) falls
    /// back to the production string.
    static func serviceName(bundleIdentifier: String?, host: String) -> String {
        "\(bundleIdentifier ?? "com.jaredatch.Pensieve").git.\(host)"
    }

    private func service(forHost host: String) -> String {
        Self.serviceName(bundleIdentifier: Bundle.main.bundleIdentifier, host: host)
    }

    private func query(forHost host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service(forHost: host)]   // Pensieve-namespaced → never a foreign item
    }

    func store(token: String, username: String, forHost host: String) throws {
        SecItemDelete(query(forHost: host) as CFDictionary)   // idempotent replace, scoped to OUR service
        var add = query(forHost: host)
        add[kSecAttrAccount as String] = username
        add[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
    }

    func credential(forHost host: String) -> GitCredential? {
        var q = query(forHost: host)
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let dict = item as? [String: Any],
              let data = dict[kSecValueData as String] as? Data,
              let token = String(data: data, encoding: .utf8) else { return nil }
        let username = (dict[kSecAttrAccount as String] as? String) ?? "x-access-token"
        return .httpsToken(username: username, token: token)
    }

    func delete(forHost host: String) throws {
        let status = SecItemDelete(query(forHost: host) as CFDictionary)   // scoped to OUR service only
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.keychain(status)
        }
    }
}

/// In-memory credentials for tests and temporary runtimes. One lock protects all dictionary access
/// when a runtime shares this store across its services and the sync coordinator.
final class InMemoryCredentialStore: CredentialStoreProtocol {
    private struct Entry {
        let username: String
        let token: String
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func store(token: String, username: String, forHost host: String) throws {
        lock.withLock { entries[host] = Entry(username: username, token: token) }
    }

    func credential(forHost host: String) -> GitCredential? {
        lock.withLock {
            guard let entry = entries[host] else { return nil }
            return .httpsToken(username: entry.username, token: entry.token)
        }
    }

    func delete(forHost host: String) throws {
        lock.withLock { _ = entries.removeValue(forKey: host) }
    }
}
