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

    func testLateJoinerUsesFlightDeadlineWithoutClaimingTwoSecondWait() async {
        let started = expectation(description: "Raw lookup starts")
        let finished = expectation(description: "Raw lookup finishes")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let origin = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        var clock = origin
        var deadlines: [UInt64] = []
        let probes = ProjectDirectoryProbes(now: { clock }, wait: { _, deadline in
            deadlines.append(deadline.uptimeNanoseconds)
            return .timedOut
        })
        let path = "/fixture/\(UUID().uuidString)"
        let lookup: (String) -> Bool = { _ in
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            finished.fulfill()
            return true
        }
        XCTAssertThrowsError(try probes.check(at: path, probe: lookup))
        await fulfillment(of: [started], timeout: 2)
        clock = origin + .milliseconds(1500)
        XCTAssertThrowsError(try probes.check(at: path, probe: lookup)) { error in
            XCTAssertEqual((error as NSError).code, Int(ETIMEDOUT))
            XCTAssertEqual(error.localizedDescription, "The folder didn't answer in time.",
                           "The joiner must reach the wait branch, not refuse an expired flight")
            XCTAssertFalse(error.localizedDescription.contains("2 seconds"))
        }
        XCTAssertEqual(deadlines, [origin.uptimeNanoseconds + 2_000_000_000,
                                   origin.uptimeNanoseconds + 2_000_000_000],
                       "Both callers must wait using the same flight deadline")
        release.signal()
        await fulfillment(of: [finished], timeout: 2)
    }

    func testExpiredFlightFailsBeforeWaitingAgain() async {
        let started = expectation(description: "Raw lookup starts")
        let finished = expectation(description: "Raw lookup finishes")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let origin = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        var clock = origin
        var waits = 0
        let probes = ProjectDirectoryProbes(now: { clock }, wait: { _, _ in
            waits += 1
            return .timedOut
        })
        let path = "/fixture/\(UUID().uuidString)"
        let lookup: (String) -> Bool = { _ in
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            finished.fulfill()
            return true
        }
        XCTAssertThrowsError(try probes.check(at: path, probe: lookup))
        await fulfillment(of: [started], timeout: 2)
        clock = origin + 3
        XCTAssertThrowsError(try probes.check(at: path, probe: lookup)) { error in
            XCTAssertEqual((error as NSError).code, Int(ETIMEDOUT))
            XCTAssertEqual(error.localizedDescription, "An earlier folder check is still running.")
        }
        XCTAssertEqual(waits, 1, "An expired flight must refuse without another wait or worker")
        release.signal()
        await fulfillment(of: [finished], timeout: 2)
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
