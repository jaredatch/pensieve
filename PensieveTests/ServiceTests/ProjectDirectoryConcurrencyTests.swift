import Darwin
import Foundation
import XCTest
@testable import Pensieve

final class ProjectDirectoryConcurrencyTests: XCTestCase {
    func testConcurrentCallersShareHealthyProbeAndItsAnswer() async throws {
        for answer in [true, false] {
            let started = expectation(description: "Raw lookup starts")
            let secondStarted = expectation(description: "Concurrent caller starts")
            let completed = expectation(description: "Both callers finish")
            completed.expectedFulfillmentCount = 2
            let release = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var probes = 0
            var answers: [Bool] = []
            var errors: [Error] = []
            let path = "/fixture/\(UUID().uuidString)"
            let files = FileService(directoryProbe: { _ in
                lock.withLock { probes += 1 }
                started.fulfill()
                _ = release.wait(timeout: .now() + 4)
                return answer
            })
            let check = {
                do {
                    let value = try files.directoryExistsFollowingLinks(at: path)
                    lock.withLock { answers.append(value) }
                } catch { lock.withLock { errors.append(error) } }
                completed.fulfill()
            }
            DispatchQueue.global(qos: .userInitiated).async { check() }
            await fulfillment(of: [started], timeout: 2)
            DispatchQueue.global(qos: .userInitiated).async { secondStarted.fulfill(); check() }
            await fulfillment(of: [secondStarted], timeout: 2)
            // A short bounded observation keeps the first lookup in flight while the second joins.
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(lock.withLock { errors.isEmpty }, "A healthy concurrent check must wait")
            release.signal()
            await fulfillment(of: [completed], timeout: 3)
            XCTAssertTrue(lock.withLock { errors.isEmpty })
            XCTAssertEqual(lock.withLock { answers }, [answer, answer])
            XCTAssertEqual(lock.withLock { probes }, 1)
        }
    }

    func testProbeRunsAtUserInitiatedPriorityOrHigher() throws {
        let files = FileService(directoryProbe: { _ in
            let qos = qos_class_self()
            XCTAssertTrue(qos == QOS_CLASS_USER_INITIATED || qos == QOS_CLASS_USER_INTERACTIVE,
                          "A synchronous caller must not wait on a utility-priority lookup")
            return true
        })
        XCTAssertTrue(try files.directoryExistsFollowingLinks(at: "/fixture/\(UUID().uuidString)"))
    }
}
