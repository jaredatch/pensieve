import Darwin
import Foundation
import XCTest
@testable import Pensieve

extension ProjectDirectoryConcurrencyTests {
    func testProductionWaitSharesDeadlineAndBroadcastsFinishedAnswer() async throws {
        let timeout = ProductionWaitFlight(test: self, answer: true)
        let finished = ProductionWaitFlight(test: self, answer: false)
        defer { timeout.release.signal(); finished.release.signal() }
        timeout.startCaller()
        finished.startCaller()
        await fulfillment(of: [timeout.started, finished.started], timeout: 3)
        try await Task.sleep(for: .milliseconds(250))
        timeout.startCaller(isJoiner: true)
        finished.startCaller(isJoiner: true)
        await fulfillment(of: [timeout.joined, finished.joined], timeout: max(timeout.remaining, finished.remaining))
        guard timeout.joinedBeforeDeadline, finished.joinedBeforeDeadline else {
            XCTFail("Scheduling delayed a joiner past its flight deadline: \(timeout.joinTiming); \(finished.joinTiming)")
            timeout.release.signal()
            finished.release.signal()
            await fulfillment(of: [timeout.firstCompleted, finished.firstCompleted, timeout.completed,
                                   finished.completed, timeout.rawFinished, finished.rawFinished], timeout: 3)
            return
        }
        finished.release.signal()
        await fulfillment(of: [timeout.firstCompleted], timeout: timeout.remaining)
        // Let the shared deadline expire before returning the held answer. A joiner with a fresh
        // two-second wait receives true instead of timing out, without a narrow elapsed-time window.
        try await Task.sleep(for: .milliseconds(50))
        timeout.release.signal()
        await fulfillment(of: [timeout.completed, finished.firstCompleted, finished.completed,
                               timeout.rawFinished, finished.rawFinished],
                          timeout: max(1, max(timeout.remaining, finished.remaining)))
        assertProductionTimeout(timeout)
        assertProductionCompletion(finished)
    }

    private func assertProductionTimeout(_ flight: ProductionWaitFlight) {
        let timeouts = flight.observations
        XCTAssertEqual(timeouts.count, 2)
        XCTAssertTrue(timeouts.allSatisfy { $0.error?.code == Int(ETIMEDOUT) })
        XCTAssertTrue(timeouts.allSatisfy { $0.error?.localizedDescription == "The folder didn't answer in time." },
                      "Both callers reach the production wait, including the late joiner")
        XCTAssertTrue(timeouts.allSatisfy { $0.returnedAt >= flight.deadline }, "Neither wait ends before its deadline")
        XCTAssertTrue(timeouts.allSatisfy { $0.returnedAt <= flight.observationDeadline },
                      "The flight deadline bounds both waits, allowing a one-second scheduling stall")
        XCTAssertEqual(flight.probeCount, 1)
    }

    private func assertProductionCompletion(_ flight: ProductionWaitFlight) {
        let answers = flight.observations
        XCTAssertEqual(answers.count, 2)
        XCTAssertTrue(answers.allSatisfy { $0.answer == false && $0.error == nil },
                      "A completed false answer releases both production waiters")
        XCTAssertLessThan(flight.rawFinishedAt, flight.deadline, "The false answer finishes before the flight deadline")
        XCTAssertTrue(answers.allSatisfy { $0.returnedAt <= flight.rawFinishedAt + ProductionWaitFlight.schedulingSlack },
                      "Completion releases both waiters, allowing a one-second scheduling stall")
        XCTAssertEqual(flight.probeCount, 1)
    }
}

/// Holds raw probes without touching disk. Only the clock is observed; both registries use
/// DispatchTime.now and the production DispatchGroup wait, with no substituted wait closure.
private final class ProductionWaitFlight {
    struct Observation {
        let answer: Bool?
        let error: NSError?
        let returnedAt: UInt64
    }
    // One delayed scheduling step plus the deliberate post-timeout release and ordinary setup.
    static let schedulingSlack: UInt64 = 1_250_000_000
    let started: XCTestExpectation
    let joined: XCTestExpectation
    let firstCompleted: XCTestExpectation
    let completed: XCTestExpectation
    let rawFinished: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let probes: ProjectDirectoryProbes
    private let clock: ProductionWaitClock
    private let path = "/fixture/" + UUID().uuidString
    private let answer: Bool
    private var results: [Observation] = []
    private var rawProbes = 0
    private var rawEnd: UInt64 = 0
    var observations: [Observation] { lock.withLock { results } }
    var probeCount: Int { lock.withLock { rawProbes } }
    var rawFinishedAt: UInt64 { lock.withLock { rawEnd } }
    var deadline: UInt64 { clock.origin + 2_000_000_000 }
    var observationDeadline: UInt64 { deadline + Self.schedulingSlack }
    var remaining: Double {
        let now = DispatchTime.now().uptimeNanoseconds
        return observationDeadline > now ? Double(observationDeadline - now) / 1_000_000_000 : 0
    }
    var joinedBeforeDeadline: Bool { clock.joinTime > clock.origin && clock.joinTime < deadline }
    var joinTiming: String { "join at \(clock.joinTime), start \(clock.origin), deadline \(deadline)" }

    init(test: XCTestCase, answer: Bool) {
        self.answer = answer
        started = test.expectation(description: "Raw probe starts")
        joined = test.expectation(description: "Second caller joins existing flight")
        firstCompleted = test.expectation(description: "Starter returns at the flight deadline")
        completed = test.expectation(description: "Both callers return")
        completed.expectedFulfillmentCount = 2
        rawFinished = test.expectation(description: "Raw probe finishes")
        let clock = ProductionWaitClock(joined: joined)
        self.clock = clock
        probes = ProjectDirectoryProbes(now: clock.read)
    }

    func startCaller(isJoiner: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try self.probes.check(at: self.path) { _ in
                self.lock.withLock { self.rawProbes += 1 }
                self.started.fulfill()
                _ = self.release.wait(timeout: .now() + 5)
                self.lock.withLock { self.rawEnd = DispatchTime.now().uptimeNanoseconds }
                self.rawFinished.fulfill()
                return self.answer
            } }
            let end = DispatchTime.now().uptimeNanoseconds
            let observation = Observation(answer: try? result.get(), error: result.failure,
                                          returnedAt: end)
            self.lock.withLock { self.results.append(observation) }
            if !isJoiner { self.firstCompleted.fulfill() }
            self.completed.fulfill()
        }
    }
}

private final class ProductionWaitClock {
    private let lock = NSLock()
    private let joined: XCTestExpectation
    private var calls = 0
    private var first: UInt64 = 0
    private var second: UInt64 = 0
    var origin: UInt64 { lock.withLock { first } }
    var joinTime: UInt64 { lock.withLock { second } }
    init(joined: XCTestExpectation) { self.joined = joined }
    func read() -> DispatchTime {
        let now = DispatchTime.now()
        lock.withLock {
            calls += 1
            if calls == 1 { first = now.uptimeNanoseconds }
            if calls == 2 { second = now.uptimeNanoseconds; joined.fulfill() }
        }
        return now
    }
}

private extension Result where Failure == Error {
    var failure: NSError? {
        if case .failure(let error) = self { return error as NSError }
        return nil
    }
}
