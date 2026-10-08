import Darwin
import XCTest
@testable import Pensieve

final class SyncLockTests: XCTestCase {
    private func tempLockPath() -> String {
        TestTemporaryDirectory.path + "PensieveSyncLockTests-\(UUID().uuidString)/sync.lock"
    }

    func testSecondAcquireIsNilWhileHeldThenSucceedsAfterRelease() {
        let path = tempLockPath()
        let first = SyncLock.tryAcquire(at: path)
        XCTAssertNotNil(first, "first acquire should succeed")
        XCTAssertNil(SyncLock.tryAcquire(at: path), "second acquire while held must be nil")
        first?.release()
        let third = SyncLock.tryAcquire(at: path)
        XCTAssertNotNil(third, "acquire after release should succeed")
        third?.release()
    }

    func testExistingParentACLDoesNotRefuseAnAccessibleLock() throws {
        let path = tempLockPath()
        let parent = (path as NSString).deletingLastPathComponent
        try FileService().createDirectory(at: parent)
        let descriptor = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { clearACLAndRemoveLockParent(parent, descriptor: descriptor) }
        let acl = try XCTUnwrap(acl_from_text(
            "!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:deny:readattr\n"))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        XCTAssertEqual(acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED), 0)
        XCTAssertThrowsError(try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true),
                             "The ACL fixture must make Foundation's parent creation fail on this machine")
        let accessible = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(accessible, 0, "The same ACL fixture must allow native open")
        guard accessible >= 0 else { return }
        close(accessible)
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: path))
        defer { held.release() }
        XCTAssertNil(try SyncLock.tryAcquireReportingErrors(at: path))
        held.release()
        let reporting = try XCTUnwrap(SyncLock.tryAcquireReportingErrors(at: path))
        reporting.release()
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

    /// Restore through the owned directory descriptor. Cleanup uses unlinkat/rmdir even if ACL
    /// clearing fails: it needs search/delete permissions, not the readattr permission we denied.
    private func clearACLAndRemoveLockParent(_ parent: String, descriptor: Int32) {
        if let empty = acl_init(0) {
            _ = acl_set_fd_np(descriptor, empty, ACL_TYPE_EXTENDED)
            acl_free(UnsafeMutableRawPointer(empty))
        }
        let removed = unlinkat(descriptor, "sync.lock", 0)
        XCTAssertTrue(removed == 0 || errno == ENOENT)
        close(descriptor)
        XCTAssertEqual(rmdir(parent), 0, "ACL fixture must leave no directory even if clearing fails")
    }
}
