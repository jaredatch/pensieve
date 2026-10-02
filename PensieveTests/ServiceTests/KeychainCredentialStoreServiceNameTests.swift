import XCTest
@testable import Pensieve

final class KeychainCredentialStoreServiceNameTests: XCTestCase {
    func testProductionServiceNameIsByteIdenticalToTheShippedForm() {
        XCTAssertEqual(
            KeychainCredentialStore.serviceName(bundleIdentifier: "com.jaredatch.Pensieve", host: "github.com"),
            "com.jaredatch.Pensieve.git.github.com"
        )
    }

    func testDebugBundleIdentifierNamespacesTheService() {
        XCTAssertEqual(
            KeychainCredentialStore.serviceName(
                bundleIdentifier: "com.jaredatch.Pensieve.debug",
                host: "github.com#install"
            ),
            "com.jaredatch.Pensieve.debug.git.github.com#install"
        )
    }

    func testMissingBundleIdentifierFallsBackToProduction() {
        XCTAssertEqual(
            KeychainCredentialStore.serviceName(bundleIdentifier: nil, host: "github.com"),
            "com.jaredatch.Pensieve.git.github.com"
        )
    }
}
