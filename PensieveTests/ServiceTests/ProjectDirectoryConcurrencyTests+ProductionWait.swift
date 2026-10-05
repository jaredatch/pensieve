import Darwin
import Foundation
import XCTest
@testable import Pensieve

extension ProjectDirectoryConcurrencyTests {
    func testProductionWaitBoundsTimeoutAndBroadcastsFinishedAnswer() async {
        let timeout = ProductionWaitFlight(test: self, answer: true, holdsProbe: true)
        let finished = ProductionWaitFlight(test: self, answer: false, holdsProbe: false)
        timeout.startCaller()
        timeout.startCaller()
        finished.startCaller()
        finished.startCaller()
        let result = await XCTWaiter.fulfillment(of: [timeout.completed, finished.completed], timeout: 15)
        // On the green path both callers have returned while the timeout probe is still held.
        // A failed bound must also drain an unbounded-wait fault without leaving blocked workers.
        timeout.releaseHeldProbe()
        if result != .completed {
            let drained = expectation(description: "Callers drain after a failed production wait bound")
            timeout.callers.notify(queue: .global()) { drained.fulfill() }
            await fulfillment(of: [drained], timeout: 15)
        }
        XCTAssertEqual(result, .completed, "Callers must return within the 15-second observation bound. "
                       + timeout.timing + "; " + finished.timing)
        assertProductionTimeout(timeout)
        assertProductionCompletion(finished)
    }

    private func assertProductionTimeout(_ flight: ProductionWaitFlight) {
        let observations = flight.observations
        XCTAssertEqual(observations.count, 2, flight.timing)
        XCTAssertTrue(observations.allSatisfy { $0.error?.code == Int(ETIMEDOUT) },
                      "Every caller times out while the raw probe remains held. " + flight.timing)
        assertProductionBound(flight)
    }

    private func assertProductionCompletion(_ flight: ProductionWaitFlight) {
        let observations = flight.observations
        XCTAssertEqual(observations.count, 2, flight.timing)
        XCTAssertTrue(observations.allSatisfy { $0.answer == false && $0.error == nil },
                      "A finished false answer releases every production waiter. " + flight.timing)
    }

    private func assertProductionBound(_ flight: ProductionWaitFlight) {
        XCTAssertTrue(flight.observations.allSatisfy { $0.returnedAt - $0.startedAt <= 10_000_000_000 },
                      "Each call returns within two seconds plus eight seconds of scheduling slack. " + flight.timing)
    }
}

/// Uses the production DispatchGroup wait. Held probes use the default monotonic clock; the
/// finished-answer clock adds eight seconds so broadcast is observed within a generous budget.
/// Completed probes answer immediately. A held probe stays blocked until callers return or the
/// observation bound fails. Its release gate stays open for a worker or second flight started late.
/// Only the two caller completions fulfill expectations; raw workers never fulfill expectations.
private final class ProductionWaitFlight {
    struct Observation {
        let answer: Bool?
        let error: NSError?
        let startedAt: UInt64
        let returnedAt: UInt64
    }
    let completed: XCTestExpectation
    let callers = DispatchGroup()
    private let release = DispatchGroup()
    private let lock = NSLock()
    private let probes: ProjectDirectoryProbes
    private let path = "/fixture/" + UUID().uuidString
    private let answer: Bool
    private let holdsProbe: Bool
    private var results: [Observation] = []
    private var releasedAt: UInt64?
    var observations: [Observation] { lock.withLock { results } }
    var timing: String {
        lock.withLock {
            let releaseTime = releasedAt.map(String.init) ?? "unreleased"
            let returns = results.map { observation in
                let relation = releasedAt.map { observation.returnedAt < $0 ? "before" : "after" } ?? "before"
                return "\(observation.returnedAt) (\(relation) release, started \(observation.startedAt))"
            }.joined(separator: ", ")
            return "\(holdsProbe ? "Held" : "Finished") probe release at \(releaseTime); returns [\(returns)]"
        }
    }

    init(test: XCTestCase, answer: Bool, holdsProbe: Bool) {
        self.answer = answer
        self.holdsProbe = holdsProbe
        probes = holdsProbe ? ProjectDirectoryProbes() : ProjectDirectoryProbes(now: { .now() + 8 })
        completed = test.expectation(description: holdsProbe ? "Held-probe callers return" : "Finished-answer callers return")
        completed.expectedFulfillmentCount = 2
        if holdsProbe { release.enter() }
    }

    func releaseHeldProbe() {
        lock.withLock {
            guard holdsProbe, releasedAt == nil else { return }
            releasedAt = DispatchTime.now().uptimeNanoseconds
            release.leave()
        }
    }

    func startCaller() {
        callers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = Result { try self.probes.check(at: self.path) { _ in
                self.release.wait()
                self.lock.withLock {
                    if self.releasedAt == nil { self.releasedAt = DispatchTime.now().uptimeNanoseconds }
                }
                return self.answer
            } }
            let end = DispatchTime.now().uptimeNanoseconds
            let observation = Observation(answer: try? result.get(), error: result.failure,
                                          startedAt: start, returnedAt: end)
            self.lock.withLock { self.results.append(observation) }
            self.completed.fulfill()
            self.callers.leave()
        }
    }
}

private extension Result where Failure == Error {
    var failure: NSError? {
        if case .failure(let error) = self { return error as NSError }
        return nil
    }
}
