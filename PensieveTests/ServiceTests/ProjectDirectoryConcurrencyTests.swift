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
            await fulfillment(of: [started], timeout: TestWait.hostedActionTimeoutSeconds)
            DispatchQueue.global(qos: .userInitiated).async { secondStarted.fulfill(); check() }
            await fulfillment(of: [secondStarted], timeout: TestWait.hostedActionTimeoutSeconds)
            // A short bounded observation keeps the first lookup in flight while the second joins.
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(lock.withLock { errors.isEmpty }, "A healthy concurrent check must wait")
            release.signal()
            await fulfillment(of: [completed], timeout: TestWait.hostedActionTimeoutSeconds)
            XCTAssertTrue(lock.withLock { errors.isEmpty })
            XCTAssertEqual(lock.withLock { answers }, [answer, answer])
            XCTAssertEqual(lock.withLock { probes }, 1)
        }
    }

    func testLateJoinerUsesFlightDeadlineWithoutClaimingTwoSecondWait() async {
        let started = expectation(description: "Raw lookup starts")
        let finished = expectation(description: "Raw lookup finishes")
        let waiting = expectation(description: "Starter reaches the controlled wait")
        let returned = expectation(description: "Starter returns")
        let release = DispatchGroup()
        release.enter()
        let flight = ControlledWaitFlight(waiting: waiting)
        let probes = ProjectDirectoryProbes(now: flight.read, wait: flight.wait)
        let path = "/fixture/\(UUID().uuidString)"
        let lookup: (String) -> Bool = { _ in
            started.fulfill()
            release.wait()
            finished.fulfill()
            return true
        }
        DispatchQueue.global(qos: .userInitiated).async {
            self.assertControlledTimeout(probes, path: path, lookup: lookup)
            flight.recordReturn()
            returned.fulfill()
        }
        await fulfillment(of: [started, waiting], timeout: TestWait.hostedActionTimeoutSeconds)
        flight.advanceToJoin()
        assertControlledTimeout(probes, path: path, lookup: lookup)
        flight.recordReturn()
        flight.resume.signal()
        await fulfillment(of: [returned], timeout: TestWait.hostedActionTimeoutSeconds)
        XCTAssertEqual(flight.deadlines, [flight.deadline, flight.deadline],
                       "Both callers must wait using the same flight deadline")
        XCTAssertEqual(flight.budgets, [2_000_000_000, 500_000_000], "The joiner waits only the remaining half second")
        XCTAssertEqual(flight.returns, [flight.deadline, flight.deadline],
                       "Both waits give up at the exact injected flight deadline")
        release.leave()
        await fulfillment(of: [finished], timeout: TestWait.hostedActionTimeoutSeconds)
    }

    private func assertControlledTimeout(_ probes: ProjectDirectoryProbes, path: String,
                                         lookup: @escaping (String) -> Bool) {
        do {
            _ = try probes.check(at: path, probe: lookup)
            XCTFail("The controlled wait must time out")
        } catch {
            XCTAssertEqual((error as NSError).code, Int(ETIMEDOUT))
            XCTAssertEqual(error.localizedDescription, "The folder didn't answer in time.",
                           "The caller must reach the wait branch, not refuse an expired flight")
            XCTAssertFalse(error.localizedDescription.contains("2 seconds"))
        }
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
        await fulfillment(of: [started], timeout: TestWait.hostedActionTimeoutSeconds)
        clock = origin + 3
        XCTAssertThrowsError(try probes.check(at: path, probe: lookup)) { error in
            XCTAssertEqual((error as NSError).code, Int(ETIMEDOUT))
            XCTAssertEqual(error.localizedDescription, "An earlier folder check is still running.")
        }
        XCTAssertEqual(waits, 1, "An expired flight must refuse without another wait or worker")
        release.signal()
        await fulfillment(of: [finished], timeout: TestWait.hostedActionTimeoutSeconds)
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

/// A held starter and a joiner at 1.5 seconds use one injected two-second flight. The joiner's
/// wait advances the clock to its supplied deadline before returning; no elapsed wall time is proof.
private final class ControlledWaitFlight {
    let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let waiting: XCTestExpectation
    private let origin = DispatchTime(uptimeNanoseconds: 1_000_000_000)
    private var clock = DispatchTime(uptimeNanoseconds: 1_000_000_000)
    private var waitDeadlines: [UInt64] = []
    private var waitBudgets: [UInt64] = []
    private var returnTimes: [UInt64] = []
    var deadline: UInt64 { origin.uptimeNanoseconds + 2_000_000_000 }
    var deadlines: [UInt64] { lock.withLock { waitDeadlines } }
    var budgets: [UInt64] { lock.withLock { waitBudgets } }
    var returns: [UInt64] { lock.withLock { returnTimes } }
    init(waiting: XCTestExpectation) { self.waiting = waiting }
    func read() -> DispatchTime { lock.withLock { clock } }
    func advanceToJoin() { lock.withLock { clock = origin + .milliseconds(1500) } }
    func recordReturn() { lock.withLock { returnTimes.append(clock.uptimeNanoseconds) } }
    func wait(_ group: DispatchGroup, until deadline: DispatchTime) -> DispatchTimeoutResult {
        let isStarter = lock.withLock {
            waitDeadlines.append(deadline.uptimeNanoseconds)
            waitBudgets.append(deadline.uptimeNanoseconds - clock.uptimeNanoseconds)
            return waitDeadlines.count == 1
        }
        if isStarter {
            waiting.fulfill()
            _ = resume.wait(timeout: .now() + 15)
        } else { lock.withLock { clock = deadline } }
        return .timedOut
    }
}
