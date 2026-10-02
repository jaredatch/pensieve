import XCTest

final class DaemonBundleTests: XCTestCase {
    func testBundleHasNoLaunchAgentsDirectory() throws {
        let appURL = try builtAppURL()
        let launchAgentsURL = appURL.appendingPathComponent("Contents/Library/LaunchAgents")
        XCTAssertFalse(FileManager.default.fileExists(atPath: launchAgentsURL.path), launchAgentsURL.path)
    }

    func testBundleStillContainsExecutableDaemon() throws {
        let appURL = try builtAppURL()
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/pensieve-daemon")
        XCTAssertTrue(FileManager.default.fileExists(atPath: executableURL.path), executableURL.path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executableURL.path), executableURL.path)
    }

    private func builtAppURL() throws -> URL {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL
        }
        if let productsDir = ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"] {
            let url = URL(fileURLWithPath: productsDir).appendingPathComponent("Pensieve.app")
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let testBundleURL = Bundle(for: Self.self).bundleURL
        let sibling = testBundleURL.deletingLastPathComponent().appendingPathComponent("Pensieve.app")
        if FileManager.default.fileExists(atPath: sibling.path) {
            return sibling
        }
        XCTFail("Could not locate Pensieve.app for bundle assertions")
        throw CocoaError(.fileNoSuchFile)
    }
}
