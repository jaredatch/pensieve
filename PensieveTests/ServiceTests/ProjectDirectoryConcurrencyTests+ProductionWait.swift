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
        await fulfillment(of: [timeout.started, finished.started], timeout: 2)
        try await Task.sleep(for: .seconds(1))
        timeout.startCaller()
        finished.startCaller()
        await fulfillment(of: [timeout.joined, finished.joined], timeout: 1)
        finished.release.signal()
        await fulfillment(of: [timeout.completed, finished.completed], timeout: 3)

        let timeouts = timeout.observations
        XCTAssertEqual(timeouts.count, 2)
        XCTAssertTrue(timeouts.allSatisfy { $0.error?.code == Int(ETIMEDOUT) })
        XCTAssertTrue(timeouts.allSatisfy { $0.error?.localizedDescription == "The folder didn't answer in time." },
                      "Both callers reach the production wait, including the late joiner")
        XCTAssertTrue(timeouts.allSatisfy { $0.flightElapsed >= 1.8 && $0.flightElapsed < 2.7 },
                      "Both waits end at the flight deadline")
        XCTAssertLessThan(timeouts.map(\.callerElapsed).min() ?? .infinity, 1.5,
                          "The joiner has only the remainder of the starter's budget")
        XCTAssertEqual(timeout.probeCount, 1)

        let answers = finished.observations
        XCTAssertEqual(answers.count, 2)
        XCTAssertTrue(answers.allSatisfy { $0.answer == false && $0.error == nil },
                      "A completed false answer releases both production waiters")
        XCTAssertTrue(answers.allSatisfy { $0.flightElapsed < 1.8 }, "Completion releases waiters before the deadline")
        XCTAssertEqual(finished.probeCount, 1)
        timeout.release.signal()
        await fulfillment(of: [timeout.rawFinished, finished.rawFinished], timeout: 2)
    }
}

/// Holds raw probes without touching disk. Only the clock is observed; both registries use
/// DispatchTime.now and the production DispatchGroup wait, with no substituted wait closure.
private final class ProductionWaitFlight {
    struct Observation {
        let answer: Bool?
        let error: NSError?
        let callerElapsed: Double
        let flightElapsed: Double
    }
    let started: XCTestExpectation
    let joined: XCTestExpectation
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
    var observations: [Observation] { lock.withLock { results } }
    var probeCount: Int { lock.withLock { rawProbes } }

    init(test: XCTestCase, answer: Bool) {
        self.answer = answer
        started = test.expectation(description: "Raw probe starts")
        joined = test.expectation(description: "Second caller joins existing flight")
        completed = test.expectation(description: "Both callers return")
        completed.expectedFulfillmentCount = 2
        rawFinished = test.expectation(description: "Raw probe finishes")
        let clock = ProductionWaitClock(joined: joined)
        self.clock = clock
        probes = ProjectDirectoryProbes(now: clock.read)
    }

    func startCaller() {
        DispatchQueue.global(qos: .userInitiated).async {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = Result { try self.probes.check(at: self.path) { _ in
                self.lock.withLock { self.rawProbes += 1 }
                self.started.fulfill()
                _ = self.release.wait(timeout: .now() + 5)
                self.rawFinished.fulfill()
                return self.answer
            } }
            let end = DispatchTime.now().uptimeNanoseconds
            let observation = Observation(answer: try? result.get(), error: result.failure,
                                          callerElapsed: Double(end - start) / 1_000_000_000,
                                          flightElapsed: Double(end - self.clock.origin) / 1_000_000_000)
            self.lock.withLock { self.results.append(observation) }
            self.completed.fulfill()
        }
    }
}

private final class ProductionWaitClock {
    private let lock = NSLock()
    private let joined: XCTestExpectation
    private var calls = 0
    private var first: UInt64 = 0
    var origin: UInt64 { lock.withLock { first } }
    init(joined: XCTestExpectation) { self.joined = joined }
    func read() -> DispatchTime {
        let now = DispatchTime.now()
        lock.withLock {
            calls += 1
            if calls == 1 { first = now.uptimeNanoseconds }
            if calls == 2 { joined.fulfill() }
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
