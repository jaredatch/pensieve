import XCTest
@testable import Pensieve

extension TestWaitTests {
    func testGateWaitAllowsASamePriorityTaskToOpenIt() async throws {
        let gate = TestWait.Gate(owner: self)
        let worker = BlockingWork.task(priority: .utility) { try gate.wait() }
        let progressed = await withCheckedContinuation { continuation in
            Thread {
                let deadline = ProcessInfo.processInfo.systemUptime + TestWait.hostedActionTimeoutSeconds
                while gate.waiterCount == 0 && ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                let didWait = gate.waiterCount == 1
                let opened = DispatchSemaphore(value: 0)
                if didWait { Task.detached(priority: .utility) { gate.open(); opened.signal() } }
                let didOpen = didWait && opened.wait(timeout: .now() + TestWait.hostedActionTimeoutSeconds) == .success
                if !didOpen { gate.open() }
                continuation.resume(returning: didOpen)
            }.start()
        }
        try await worker.value
        XCTAssertTrue(progressed, "A proven gate waiter must leave its own priority available to the opener")
    }

    func testEarlyOwnerExitAbandonsHeldStubWithoutReturningItsValue() async throws {
        var worker: Task<String, Error>?
        // Registered first so this assertion runs after the gate's automatic teardown.
        addTeardownBlock {
            guard let worker else { return XCTFail("stub was not started") }
            do {
                let value = try await worker.value
                XCTFail("Abandonment must not return the stub's canned value: \(value)")
            } catch {
                XCTAssertEqual(error as? TestWait.GateFailure, .abandoned)
            }
        }
        let gate = TestWait.Gate(owner: self)
        worker = BlockingWork.task {
            try gate.wait()
            return "stub value"
        }
        await TestWait.until(failureMessage: "stub did not reach gate") { gate.waiterCount == 1 }
        expectGateFailureAtTeardown(.abandoned)
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { $0.compactDescription.contains("TestWaitIntentionalOwnerExit") }
        XCTExpectFailure("The owner exits by throwing while its stub is held", options: options)
        throw NSError(domain: "TestWaitIntentionalOwnerExit", code: 1)
    }

    func testNormalGateOpeningAllowsTheStubToContinue() {
        let gate = TestWait.Gate(owner: self)
        gate.open()
        XCTAssertNoThrow(try gate.wait(timeout: .zero))
        XCTAssertNil(gate.failure)
    }

    func testFinishPreservesUnconsumedOpenPermits() async throws {
        let gate = TestWait.Gate(owner: self)
        gate.open()
        gate.open()
        gate.finish()

        let worker = BlockingWork.task { () throws -> String in
            try gate.wait(timeout: .zero)
            try gate.wait(timeout: .zero)
            return "stub value"
        }
        let value = try await worker.value
        XCTAssertEqual(value, "stub value")
        XCTAssertNil(gate.failure)
    }

    func testGateTimeoutThrowsAndIsReportedAtTeardown() async {
        let gate = TestWait.Gate(owner: self)
        let worker = BlockingWork.task(priority: .utility) {
            try gate.wait(timeout: .milliseconds(50)) // upper-bound: Deliberately expire a never-opened gate.
        }
        switch await worker.result {
        case let .failure(error): XCTAssertEqual(error as? TestWait.GateFailure, .timedOut)
        case .success: XCTFail("A never-opened gate must throw when its deadline expires")
        }
        expectGateFailureAtTeardown(.timedOut)
        XCTAssertEqual(gate.failure, .timedOut)
    }

    func testFinishAbandonsOnlyWaitsWithoutPermits() async {
        let gate = TestWait.Gate(owner: self)
        let workers = (0..<2).map { _ in
            BlockingWork.task { () -> Bool in
                do {
                    try gate.wait()
                    return true
                } catch {
                    return false
                }
            }
        }
        await TestWait.until(failureMessage: "both stubs did not reach gate") { gate.waiterCount == 2 }
        gate.open()
        gate.abandon()
        expectGateFailureAtTeardown(.abandoned)
        var successes = 0
        for worker in workers where await worker.value { successes += 1 }
        XCTAssertEqual(successes, 1, "Exactly one granted permit must survive cleanup")
        XCTAssertEqual(gate.failure, .abandoned)
    }

    func expectGateFailureAtTeardown(_ failure: TestWait.GateFailure) {
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { $0.compactDescription.contains("Gate did not open normally: \(failure)") }
        XCTExpectFailure("Only the automatic gate teardown check must fail", options: options)
    }
}
