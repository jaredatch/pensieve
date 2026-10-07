import XCTest
@testable import Pensieve

@MainActor
final class BlockingWorkTests: XCTestCase {
    func testCancellationJoinsGitBeforeReturningAndReleasingSyncLock() async throws {
        let block = try GitBlockingFixture()
        defer { block.release(); try? block.cleanup() }
        let lockPath = block.root + "/sync.lock"
        let returned = UpdateReviewRecorder<Bool>()
        let worker = Task {
            let lock = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
            defer { lock.release(); returned.append(true) }
            return try await BlockingWork.run(priority: .utility) {
                try block.run()
                return Task.isCancelled
            }
        }
        await TestWait.until(failureMessage: "git did not enter its blocked call") { block.isBlocked }
        worker.cancel()
        // Let a cancellation continuation run on the main actor while git remains held.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(SyncLock.tryAcquire(at: lockPath), "Cancellation cannot release the caller's mutation lock")
        XCTAssertTrue(returned.values.isEmpty, "The await cannot return while the git child is alive")
        block.release()
        let observedCancellation = try await worker.value
        XCTAssertTrue(observedCancellation, "The synchronous operation must keep its worker's cancellation identity")
        XCTAssertFalse(block.isBlocked, "The runner must reap git before returning")
        XCTAssertEqual(returned.values, [true])
        let nextLock = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
        nextLock.release()
    }
}
