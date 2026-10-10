import Darwin
import XCTest
@testable import Pensieve

@MainActor
final class GitBlockingFixtureTests: XCTestCase {
    func testAbandonedFakeGitExpiresWithinTwoMinutesWithoutCleanup() async throws {
        var fixture: GitBlockingFixture? = try GitBlockingFixture()
        let root = try XCTUnwrap(fixture).root
        let process = try start(try XCTUnwrap(fixture))
        defer { stop(process); try? FileService().deleteDirectory(at: root) }
        await TestWait.until(failureMessage: "Fake git never announced readiness") { fixture?.isBlocked == true }
        let started = ContinuousClock.now
        fixture = nil
        await TestWait.until(timeout: .seconds(115), failureMessage: "Abandoned fake git exceeded two minutes") {
            !process.isRunning
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(120))
        XCTAssertEqual(process.isRunning ? nil : process.terminationStatus, 124)
        XCTAssertTrue(FileService().directoryExists(at: root), "Expiry must work without deleting the fixture or releasing it")
    }

    func testFakeGitExitsAfterFixtureCleanupWithoutARelease() async throws {
        let fixture = try GitBlockingFixture()
        let process = try start(fixture)
        defer { stop(process); try? fixture.cleanup() }
        await TestWait.until(failureMessage: "Fake git never announced readiness") { fixture.isBlocked }
        try fixture.cleanup()
        await TestWait.until(timeout: .seconds(5), // upper-bound: Removing the fixture must promptly stop its child.
                             failureMessage: "Fake git outlived its removed fixture") {
            !process.isRunning
        }
        XCTAssertEqual(process.isRunning ? nil : process.terminationStatus, 124)
    }

    private func start(_ fixture: GitBlockingFixture) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: fixture.root + "/git")
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func stop(_ process: Process) {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
