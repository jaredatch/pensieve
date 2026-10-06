import XCTest
@testable import Pensieve

@MainActor
final class UpstreamHistorySequenceSafetyTests: UpstreamHistoryCacheTestCase {
    nonisolated private static func callbackThread(_ name: String) -> String {
        "\(name):\(Thread.isMainThread)"
    }

    func testEveryCallbackHopsToMainActorFromDetachedWork() async throws {
        let calls = HistorySequenceCalls()
        let hooks = UpstreamHistorySequenceHooks(
            started: { _, _ in calls.append(Self.callbackThread("started")) },
            enter: { _ in calls.append(Self.callbackThread("enter")) },
            finish: { _ in calls.append(Self.callbackThread("finish")) },
            waiting: { _ in calls.append(Self.callbackThread("waiting")) },
            resume: { _ in calls.append(Self.callbackThread("resume")) },
            published: { _, _ in calls.append(Self.callbackThread("published")) },
            passed: { _, _, _ in calls.append(Self.callbackThread("passed")) },
            applied: { _ in calls.append(Self.callbackThread("applied")) }
        )
        await Task.detached {
            let id = UUID()
            await hooks.started(.read, id)
            await hooks.enter(id)
            await hooks.finish(id)
            await hooks.waiting(id)
            await hooks.resume(id)
            await hooks.published(.idle, nil)
            await hooks.passed(.start, id, "")
            await hooks.applied(id)
        }.value
        XCTAssertEqual(calls.values, ["started", "enter", "finish", "waiting", "resume", "published", "passed", "applied"]
            .map { "\($0):true" })
        let fixture = try sequenceFixture(.empty)
        fixture.model.sequenceHooks = hooks
        let task = fixture.model.sequenceTask(.read, id: UUID(), priority: .utility) { true }
        _ = await fixture.model.sequenceValue(task, id: UUID())
        XCTAssertFalse(calls.values.contains(where: { $0.hasSuffix(":false") }), "\(calls.values)")
    }

    func testSignalRechecksAfterNotificationDuringRegistration() async {
        let signal = TestWait.Signal()
        var ready = false
        let result = await signal.wait(timeout: .seconds(TestWait.hostedActionTimeoutSeconds)) {
            let snapshot = ready
            if !ready {
                ready = true
                signal.notify()
            }
            return snapshot
        }
        XCTAssertEqual(result, .satisfied, "A notification before registration must not be lost")
    }

    func testSignalRechecksConditionAfterWakeup() async throws {
        let signal = TestWait.Signal()
        var ready = false
        var checks = 0
        var returned: TestWait.SignalOutcome?
        let waiter = Task {
            returned = await signal.wait(timeout: .seconds(TestWait.hostedActionTimeoutSeconds)) { checks += 1; return ready }
        }
        await TestWait.until(failureMessage: "Waiter did not register") { checks >= 2 }
        ready = true
        signal.notify()
        ready = false
        let notifiedChecks = checks
        await TestWait.until(failureMessage: "Waiter did not re-check and suspend again") {
            returned != nil || checks >= notifiedChecks + 2
        }
        XCTAssertGreaterThanOrEqual(checks, notifiedChecks + 2, "Must observe both re-check and re-registration")
        XCTAssertNil(returned, "A notification is not proof the condition still holds")
        ready = true
        signal.notify()
        await waiter.value
        XCTAssertEqual(returned, .satisfied)
    }

    func testHungRequestReportsFailureBeforeBoundedCleanup() async throws {
        let flow = UpstreamHistorySequenceHarness()
        flow.frontierTimeout = .milliseconds(20)
        flow.cleanupTimeout = .milliseconds(300)
        flow.timeoutThreadSample = { nil } // Deliberate timeout: keep the real failure assertions, omit sampling.
        var held: CheckedContinuation<Void, Never>?
        flow.enqueue("A") {
            flow.hooks.passed(.request, nil, "A")
            await withCheckedContinuation { held = $0 }
        }
        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        options.issueMatcher = { $0.compactDescription.contains("Timed out waiting for cleanup") }
        var cleanupIssues = 0
        flow.cleanupReport = { message, file, line in
            cleanupIssues += 1
            XCTExpectFailure("The deliberately stuck run must fail cleanup", options: options) {
                XCTFail(message, file: file, line: line)
            }
        }
        var messages: [String] = []
        var returned = false
        let run = Task {
            _ = await flow.checkRun(report: {
                messages.append($0)
                XCTAssertFalse(flow.tasks.contains(where: \.isCancelled), "Report before cleanup cancels stuck tasks")
            }, body: { try await flow.release("A.request") })
            returned = true
        }
        await TestWait.until(failureMessage: "Request did not reach the non-gate hold") { held != nil }
        await TestWait.until(failureMessage: "Cleanup did not return within the generous test bound") { returned }
        XCTAssertEqual(messages.count, 1, "The frontier failure must be reported while cleanup is still hung")
        XCTAssertTrue(messages.first?.contains("A.request") == true)
        XCTAssertTrue(messages.first?.contains("frontier") == true)
        XCTAssertTrue(returned, "Cleanup must return even when the request ignores cancellation")
        held?.resume()
        await run.value
        XCTAssertEqual(cleanupIssues, 1)
        flow.cleanupReport = { XCTFail($0, file: $1, line: $2) }
        await flow.close()
    }

    func testMissingScenarioIsRejected() {
        var results = HistorySequenceCoverage.expected
        let omitted = "disk-true-false-false"
        results.removeValue(forKey: omitted)
        XCTAssertThrowsError(try HistorySequenceCoverage.validateAll(results, report: { _ in })) { error in
            XCTAssertTrue(String(describing: error).contains(omitted))
        }
    }

    func testAllScenarioCountsAreReportedBeforeAnyDriftFailure() {
        var results = HistorySequenceCoverage.expected
        let first = "disk-false-false-false"
        let last = "memory-true-false-true"
        results[first] = (0, 0)
        results[last] = (0, 0)
        var reports: [String] = []
        XCTAssertThrowsError(try HistorySequenceCoverage.validateAll(results, report: { reports.append($0) })) { error in
            XCTAssertTrue(String(describing: error).contains(first))
            XCTAssertTrue(String(describing: error).contains(last))
        }
        XCTAssertEqual(reports.count, HistorySequenceCoverage.expected.count)
        for name in HistorySequenceCoverage.expected.keys {
            XCTAssertTrue(reports.contains(where: { $0.contains(name) }), "Missing counts for \(name)")
        }
    }
}
