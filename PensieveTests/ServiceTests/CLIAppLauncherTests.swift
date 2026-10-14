import XCTest
@testable import Pensieve

final class CLIAppLauncherTests: XCTestCase {
    @MainActor
    func testNoDesktopAndUnknownDesktopRefuseBeforeLaunching() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let query = Process()
        query.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        query.arguments = ["-B", root.appendingPathComponent("script/cli_desktop_session_test.py").path]
        let result = try await BlockingWork.run {
            XCTAssertFalse(Thread.isMainThread, "external probes must leave the host's main thread free")
            return try CLIProcessProbe.run(query)
        }
        XCTAssertFalse(result.timedOut, "the compile-and-query probe exceeded its deadline")
        XCTAssertEqual(result.status, 0, "logged-in GUI users must be reachable from the CLI")
        let session = SessionProbe()
        let launcher = CLIAppLauncher(fileService: FileService(), desktopSession: session, environment: [:])
        let path = "/unused-launch-fixture.app"
        let noDesktop = try XCTUnwrap(launcher.launch(appPath: path, bundleID: "p58.fixture",
            deadline: SocketTransport.deadline(after: 1)))
        XCTAssertEqual(session.calls, 1, "the external session query must be reached")
        XCTAssertEqual(noDesktop.exitCode, 3)
        XCTAssertEqual(noDesktop.envelope.error?.code, "no_desktop_session")
        XCTAssertTrue(try XCTUnwrap(noDesktop.envelope.error?.hint).contains("Status, log and deployment list"))
        session.fails = true
        let unknown = try XCTUnwrap(launcher.launch(appPath: path, bundleID: "p58.fixture",
            deadline: SocketTransport.deadline(after: 1)))
        XCTAssertEqual(session.calls, 2)
        XCTAssertEqual(unknown.exitCode, 3)
        XCTAssertEqual(unknown.envelope.error?.code, "app_unavailable", "a failed query is not a missing desktop")
        XCTAssertTrue(try XCTUnwrap(unknown.envelope.error?.message).contains("fixture query failed"))
    }

    @MainActor
    func testProbeLetsItsInnerTimeoutReportBeforeTheOuterDeadline() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import subprocess, sys
        try: subprocess.run([sys.executable, '-c', 'import time; time.sleep(90)'], timeout=63)
        except subprocess.TimeoutExpired:
            print('inner fixture step timed out', flush=True)
            sys.exit(23)
        """]
        let output = Pipe()
        process.standardOutput = output
        let result = try await BlockingWork.run { try CLIProcessProbe.run(process) }
        XCTAssertFalse(result.timedOut, "the inner timeout must report before the outer watchdog fires")
        XCTAssertEqual(result.status, 23)
        XCTAssertEqual(String(bytes: try output.fileHandleForReading.readToEnd() ?? Data(), encoding: .utf8),
                       "inner fixture step timed out\n")
    }

    @MainActor
    func testTimedOutProbeLeavesTheStandardDiagnosticRecord() async throws {
        let files = FileService()
        let directory = TestTemporaryDirectory.path + "CLIProbeDiagnostics-" + UUID().uuidString
        try files.createDirectory(at: directory)
        defer { try? files.deleteDirectory(at: directory) }
        let observer = TestTimeoutDiagnostics(environment: ["PENSIEVE_TEST_DIAGNOSTICS_DIR": directory], output: { _ in })
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import time; time.sleep(4)"]
        let result = try await BlockingWork.run {
            try CLIProcessProbe.run(process, timeout: 0.1, recordTimeout: { // upper-bound: exercise forced timeout and its report
                observer.recordSnapshot($0, threadSample: "CLI fixture threads")
            })
        }
        XCTAssertTrue(result.timedOut)
        observer.testCase(self, didRecord: XCTIssue(type: .assertionFailure, compactDescription: "CLI probe timed out"))
        let reports = try files.listDirectory(at: directory)
        let state = try XCTUnwrap(reports.first { $0.hasSuffix("-state.txt") }, "a timed-out CLI probe must leave diagnostics")
        let text = try files.readFile(at: directory + "/" + state)
        XCTAssertTrue(text.contains("CLI process probe timed out"))
        XCTAssertTrue(text.contains("pid=\(result.pid)"))
        XCTAssertTrue(text.contains("group=\(result.pid)"))
        XCTAssertEqual(try files.readFile(at: directory + "/" + XCTUnwrap(reports.first { $0.hasSuffix("-threads.txt") })),
                       "CLI fixture threads")
    }
}

private final class SessionProbe: CLIDesktopSessionReading {
    var calls = 0
    var fails = false

    func hasGraphicAccess() throws -> Bool {
        calls += 1
        if fails { throw SessionProbeError.failed }
        return false
    }
}

private enum SessionProbeError: LocalizedError {
    case failed
    var errorDescription: String? { "fixture query failed" }
}
