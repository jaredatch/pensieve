import XCTest
@testable import Pensieve

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

    func testRunCommandEntersNativeWorkerWithMainThreadGuardEnabled() throws {
        let files = FileService()
        let root = TestTemporaryDirectory.path + "DaemonEntry-" + UUID().uuidString
        let home = root + "/home"
        try files.createDirectory(at: home + "/.pensieve")
        defer { try? files.deleteDirectory(at: root) }
        try NativeTestWork.run { try TestPaths.git.initRepository(at: home + "/.pensieve") }
        let process = Process()
        process.executableURL = try builtAppURL().appendingPathComponent("Contents/MacOS/pensieve-daemon")
        process.arguments = ["run"]
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = home
        process.environment = environment
        let output = Pipe()
        let diagnostic = Pipe()
        process.standardOutput = output
        process.standardError = diagnostic
        try process.run()
        let drained = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()
        let reads: [() -> Void] = [
            { stdoutData = output.fileHandleForReading.readDataToEndOfFile() },
            { stderrData = diagnostic.fileHandleForReading.readDataToEndOfFile() }
        ]
        for read in reads {
            drained.enter()
            Thread { read(); drained.leave() }.start()
        }
        defer {
            if process.isRunning { process.terminate() }
            drained.wait()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard !process.isRunning else { return XCTFail("Daemon run did not finish") }
        drained.wait()
        let stderr = try XCTUnwrap(String(data: stderrData, encoding: .utf8))
        XCTAssertEqual(process.terminationStatus, 0, stderr)
        XCTAssertFalse(stderr.contains("Git called on the main thread"), stderr)
        XCTAssertEqual(try XCTUnwrap(String(data: stdoutData, encoding: .utf8)),
                       "pensieve-daemon skipped noRemote\n")
        XCTAssertTrue(files.fileExists(at: home + "/Library/Application Support/Pensieve/daemon-status.json"))
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
