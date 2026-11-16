import Foundation
import XCTest
@testable import Pensieve

/// A real sync waiter queued during launch's lock hold. No save is cancelled while waiting;
/// every caller releases the helper and drains the queue before fixture teardown.
final class DeletionRestartSyncHold {
    private let started = DispatchSemaphore(value: 0)
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let guardLock = NSLock()
    private var didStart = false
    let acquired = XCTestExpectation(description: "Sync takes the lock after launch")
    let finished = XCTestExpectation(description: "Sync releases its lock")

    func start(lockPath: String, beforeRelease: @escaping () throws -> Void = {}) {
        guardLock.lock()
        defer { guardLock.unlock() }
        guard !didStart else { return }
        didStart = true
        Thread.detachNewThread {
            self.started.signal()
            do {
                let held = try SyncLock.waitForSave(at: lockPath)
                defer { held.release() }
                self.acquired.fulfill()
                XCTAssertEqual(self.releaseSignal.wait(timeout: .now() + TestWait.hostedActionTimeoutSeconds), .success)
                try beforeRelease()
            } catch { XCTFail("Sync helper failed: \(error)") }
            self.finished.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + TestWait.hostedActionTimeoutSeconds), .success)
        // Let flock enqueue before launch releases. Callers assert the actual lock and disk state.
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertNil(SyncLock.tryAcquire(at: lockPath))
    }

    func release() { releaseSignal.signal() }
}
