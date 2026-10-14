import XCTest
@testable import Pensieve

final class CLIAppLauncherTests: XCTestCase {
    func testNoDesktopAndUnknownDesktopRefuseBeforeLaunching() throws {
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
