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
    }
}
