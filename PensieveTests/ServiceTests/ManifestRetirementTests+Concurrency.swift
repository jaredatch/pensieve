import XCTest
@testable import Pensieve

extension ManifestRetirementTests {
    func testConcurrentManifestWritersSerializeWholeBuildAndSwap() throws {
        let firstOpened = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondAttempted = DispatchSemaphore(value: 0)
        let secondOpened = DispatchSemaphore(value: 0)
        let order = ManifestWriteOrder()
        let finished = DispatchGroup()
        let errors = ManifestWriteErrors()
        let first = ImportPublicationFileService()
        first.beforeWrite = { path, _ in
            guard path.hasSuffix("/manifest.yaml") else { return }
            firstOpened.signal()
            if releaseFirst.wait(timeout: .now() + TestWait.heldFixtureTimeoutSeconds) != .success {
                errors.record(DeployStubFailure())
            }
        }
        let second = ImportPublicationFileService()
        second.beforeWrite = { path, _ in
            guard path.hasSuffix("/manifest.yaml") else { return }
            order.record("second opened")
            secondOpened.signal()
        }
        let root = try XCTUnwrap(root)
        let snapshot = empty
        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            do { try ManifestService(fileService: first).write(snapshot, toRoot: root) } catch { errors.record(error) }
        }
        XCTAssertEqual(firstOpened.wait(timeout: .now() + TestWait.hostedActionTimeoutSeconds), .success)
        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            do {
                try ManifestService(fileService: second, writeLockAttempted: { acquired in
                    order.record(acquired ? "second acquired" : "second blocked")
                    secondAttempted.signal()
                }).write(snapshot, toRoot: root)
            } catch { errors.record(error) }
        }
        XCTAssertEqual(secondAttempted.wait(timeout: .now() + TestWait.hostedActionTimeoutSeconds), .success)
        XCTAssertEqual(order.values, ["second blocked"], "second writer must encounter the held process lock")
        XCTAssertEqual(secondOpened.wait(timeout: .now() + 0.5), .timedOut, // upper-bound: Observe held-lock exclusion.
                       "second writer entered the locked region before the first writer was released")
        order.record("first released")
        releaseFirst.signal()
        XCTAssertEqual(secondOpened.wait(timeout: .now() + TestWait.hostedActionTimeoutSeconds), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + TestWait.hostedActionTimeoutSeconds), .success)
        XCTAssertTrue(errors.values.isEmpty, "\(errors.values)")
        XCTAssertEqual(order.values, ["second blocked", "first released", "second opened"])
        XCTAssertEqual(try manifest.read(fromRoot: root), snapshot)
    }

}

/// Only records cross-thread test errors; all modeled I/O stays in the temporary store's FileService.
private final class ManifestWriteErrors {
    private let lock = NSLock()
    private var errors: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return errors }
    func record(_ error: Error) { lock.lock(); defer { lock.unlock() }; errors.append(error.localizedDescription) }
}

/// Ordered cross-thread checkpoint events; the semaphore publishes the lock-attempt event before inspection.
private final class ManifestWriteOrder {
    private let lock = NSLock()
    private var events: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return events }
    func record(_ event: String) { lock.lock(); defer { lock.unlock() }; events.append(event) }
}
