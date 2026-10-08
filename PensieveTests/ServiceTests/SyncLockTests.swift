import Darwin
import XCTest
@testable import Pensieve

final class SyncLockTests: XCTestCase {
    private func tempLockPath() -> String {
        TestTemporaryDirectory.path + "PensieveSyncLockTests-\(UUID().uuidString)/sync.lock"
    }

    func testSecondAcquireIsNilWhileHeldThenSucceedsAfterRelease() throws {
        let path = tempLockPath()
        let parent = (path as NSString).deletingLastPathComponent
        let target = parent + "-acl"
        let files = FileService()
        try files.createDirectory(at: target)
        defer {
            try? chmodACL(["-N"], at: target)
            try? files.deleteDirectory(at: target)
            try? files.deleteDirectory(at: parent)
        }
        try chmodACL(["+a", "everyone deny readattr"], at: target)
        // This ACL prevents Foundation's mkdir check; search and child creation still permit open/flock.
        XCTAssertThrowsError(try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true),
                             "fixture must exercise a mkdir error on an accessible lock parent")
        for path in [path, target + "/sync.lock"] {
            let first = SyncLock.tryAcquire(at: path)
            XCTAssertNotNil(first, "first acquire should succeed")
            XCTAssertNil(SyncLock.tryAcquire(at: path), "second acquire while held must be nil")
            XCTAssertNil(try SyncLock.tryAcquireReportingErrors(at: path), "reporting acquire also refuses contention")
            first?.release()
            let third = SyncLock.tryAcquire(at: path)
            XCTAssertNotNil(third, "acquire after release should succeed")
            third?.release()
            let reporting = try XCTUnwrap(SyncLock.tryAcquireReportingErrors(at: path))
            reporting.release()
        }
    }

    func testReleaseIsIdempotent() {
        let path = tempLockPath()
        let lock = SyncLock.tryAcquire(at: path)
        XCTAssertNotNil(lock)
        lock?.release()
        lock?.release()   // second release must be a harmless no-op (no crash / double-close)
        XCTAssertNotNil(SyncLock.tryAcquire(at: path), "store is free again after release")
    }

    func testUnopenablePathFailsSafeToNil() {
        // A path whose parent cannot be created (a component that is a file, not a dir) → open fails → nil.
        let base = TestTemporaryDirectory.path + "PensieveSyncLockTests-\(UUID().uuidString)"
        try? "x".write(toFile: base, atomically: true, encoding: .utf8)   // `base` is now a FILE
        XCTAssertNil(SyncLock.tryAcquire(at: base + "/child/sync.lock"),
                     "an unopenable lock path must fail safe to nil, not throw or proceed")
        XCTAssertThrowsError(try SyncLock.tryAcquireReportingErrors(at: base + "/child/sync.lock")) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ENOTDIR, "report the failed open, not mkdir")
        }
    }

    /// Only changes ACLs in the test's fresh tree. The real chmod has a finite wait and is reaped on timeout.
    private func chmodACL(_ arguments: [String], at path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments + [path]
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let completed = exited.wait(timeout: .now() + TestWait.hostedActionTimeoutSeconds) == .success
        if !completed {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        XCTAssertTrue(completed, "fixture chmod must finish within the shared wait bound")
        XCTAssertEqual(process.terminationStatus, 0, "fixture chmod must succeed")
    }
}
