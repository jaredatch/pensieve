import XCTest
import Security
@testable import Pensieve

/// PLAN-08 / 08.2 — CredentialStore: in-memory semantics, a real-Keychain round-trip against a
/// throwaway host, and proof that our Pensieve-namespaced delete leaves a same-host FOREIGN keychain
/// item untouched (no broad host-keyed clobber).
final class CredentialStoreTests: XCTestCase {

    // MARK: In-memory

    func testInMemoryStoreRoundTrip() throws {
        let store = InMemoryCredentialStore()
        XCTAssertNil(store.credential(forHost: "example.com"))
        try store.store(token: "tok", username: "user", forHost: "example.com")
        guard case let .httpsToken(username, token) = store.credential(forHost: "example.com") else {
            return XCTFail("expected a stored credential")
        }
        XCTAssertEqual(username, "user")
        XCTAssertEqual(token, "tok")
        try store.delete(forHost: "example.com")
        XCTAssertNil(store.credential(forHost: "example.com"))
    }

    // MARK: Real Keychain (throwaway host)

    func testKeychainRoundTripOnThrowawayHost() throws {
        let store = KeychainCredentialStore()
        let host = "pensieve-test-\(UUID().uuidString).invalid"
        addTeardownBlock { try? store.delete(forHost: host) }

        XCTAssertNil(store.credential(forHost: host))
        try store.store(token: "pat-123", username: "x-access-token", forHost: host)
        guard case let .httpsToken(username, token) = store.credential(forHost: host) else {
            return XCTFail("expected a Keychain credential")
        }
        XCTAssertEqual(username, "x-access-token")
        XCTAssertEqual(token, "pat-123")
        try store.delete(forHost: host)
        XCTAssertNil(store.credential(forHost: host))
    }

    func testInstallSlotIsNamespacedFromSyncSlot() throws {
        let store = KeychainCredentialStore()
        let baseHost = "pensieve-test-\(UUID().uuidString).invalid"
        let installHost = CredentialHost.installNamespace(for: baseHost)
        addTeardownBlock {
            try? store.delete(forHost: baseHost)
            try? store.delete(forHost: installHost)
        }

        XCTAssertEqual(CredentialHost.githubInstall, "github.com#install")
        try store.store(token: "sync-decoy", username: "sync-user", forHost: baseHost)
        try store.store(token: "install-secret", username: "x-access-token", forHost: installHost)

        XCTAssertEqual(
            store.credential(forHost: baseHost),
            .httpsToken(username: "sync-user", token: "sync-decoy")
        )
        XCTAssertEqual(
            store.credential(forHost: installHost),
            .httpsToken(username: "x-access-token", token: "install-secret")
        )

        try store.delete(forHost: installHost)
        XCTAssertNil(store.credential(forHost: installHost))
        XCTAssertEqual(
            store.credential(forHost: baseHost),
            .httpsToken(username: "sync-user", token: "sync-decoy")
        )

        try store.store(token: "install-secret", username: "x-access-token", forHost: installHost)
        try store.delete(forHost: baseHost)
        XCTAssertNil(store.credential(forHost: baseHost))
        XCTAssertEqual(
            store.credential(forHost: installHost),
            .httpsToken(username: "x-access-token", token: "install-secret")
        )
    }

    // MARK: Namespacing safety (the decoy)

    func testDeleteLeavesForeignSameHostItemUntouched() throws {
        let store = KeychainCredentialStore()
        let host = "pensieve-test-\(UUID().uuidString).invalid"
        let foreignService = "com.other.app.\(host)"

        // Plant a decoy generic-password item under a DIFFERENT service for the SAME host.
        let decoy: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: foreignService,
            kSecAttrAccount as String: "someone",
            kSecValueData as String: Data("foreign-secret".utf8)
        ]
        SecItemDelete(decoy as CFDictionary)
        XCTAssertEqual(SecItemAdd(decoy as CFDictionary, nil), errSecSuccess)
        addTeardownBlock {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: foreignService
            ] as CFDictionary)
        }

        // Store then delete OUR credential for the same host.
        try store.store(token: "ours", username: "x-access-token", forHost: host)
        addTeardownBlock { try? store.delete(forHost: host) }
        try store.delete(forHost: host)

        // The decoy under the foreign service still reads back — our delete was scoped to our service.
        let readBack: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: foreignService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(readBack as CFDictionary, &item)
        XCTAssertEqual(status, errSecSuccess, "the foreign same-host item must survive our delete")
        XCTAssertEqual(item as? Data, Data("foreign-secret".utf8))
    }
}
