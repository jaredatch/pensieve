import Darwin
import XCTest
@testable import Pensieve

@MainActor
final class GitBlockingFixtureTests: XCTestCase {
    func testAbandonedFakeGitWaitsForShortLifetimeThenExpiresWithoutCleanup() async throws {
        var fixture: GitBlockingFixture? = try GitBlockingFixture(lifetime: 2)
        let root = try XCTUnwrap(fixture).root
        let process = makeProcess(try XCTUnwrap(fixture))
        let exits = UpdateReviewRecorder<ContinuousClock.Instant>()
        process.terminationHandler = { _ in exits.append(.now) }
        try process.run()
        defer { stop(process); try? FileService().deleteDirectory(at: root) }
        fixture = nil
        await TestWait.until(failureMessage: "Fake git never announced readiness") {
            FileService().fileExists(at: root + "/ready")
        }
        let ready = ContinuousClock.now
        await TestWait.until(timeout: .seconds(5), // upper-bound: Bound expiry after readiness, excluding process launch.
                             failureMessage: "Abandoned fake git ignored its short lifetime") {
            !process.isRunning && !exits.values.isEmpty
        }
        let elapsed = try XCTUnwrap(exits.values.first) - ready
        // Bash's whole-second SECONDS allows a two-second lifetime to end after about one second.
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(1), "Fake git must wait out its lifetime before expiring")
        XCTAssertLessThan(elapsed, .seconds(5))
        XCTAssertEqual(process.isRunning ? nil : process.terminationStatus, 124)
        XCTAssertEqual(try FileService().readFile(at: root + "/ready"), String(process.processIdentifier),
                       "Readiness remains observable after the child has expired")
        XCTAssertTrue(FileService().directoryExists(at: root), "Expiry must work without deleting the fixture or releasing it")
    }

    func testFakeGitExitsAfterFixtureCleanupWithoutARelease() async throws {
        let fixture = try GitBlockingFixture()
        let process = makeProcess(fixture)
        try process.run()
        defer { stop(process); try? fixture.cleanup() }
        await TestWait.until(failureMessage: "Fake git never announced readiness") { fixture.isBlocked }
        try fixture.cleanup()
        await TestWait.until(timeout: .seconds(5), // upper-bound: Removing the fixture must promptly stop its child.
                             failureMessage: "Fake git outlived its removed fixture") {
            !process.isRunning
        }
        XCTAssertEqual(process.isRunning ? nil : process.terminationStatus, 124)
    }

    private func makeProcess(_ fixture: GitBlockingFixture) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: fixture.root + "/git")
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    private func stop(_ process: Process) {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
