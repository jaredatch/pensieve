import AppKit
import XCTest
@testable import Pensieve

@MainActor
final class TestHostGuardTests: XCTestCase {
    func testDetectorTrueWhenXCTestEnvPresent() {
        XCTAssertTrue(
            TestHostGuard.isActive(
                environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]
            )
        )
    }

    func testDetectorFalseWhenAbsent() {
        XCTAssertFalse(TestHostGuard.isActive(environment: ["OTHER_VARIABLE": "value"]))
    }

    func testHostAppHasNoRuntime() throws {
        // SwiftUI's adaptor wraps the app delegate inside its own NSApp.delegate, so the REAL
        // PensieveAppDelegate is reachable only through its adaptor-created instance — absent
        // instance (guard not wired / host not launched through PensieveMain) fails the unwrap.
        let delegate = try XCTUnwrap(PensieveAppDelegate.shared)
        XCTAssertTrue(TestHostGuard.isActive())
        XCTAssertNil(delegate.runtime)
    }
}
