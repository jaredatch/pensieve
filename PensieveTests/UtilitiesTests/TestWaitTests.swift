import XCTest

@MainActor
final class TestWaitTests: XCTestCase {
    func testTimeoutObserverWasInstalledOnMainThreadBeforeTests() {
        XCTAssertTrue(TestTimeoutDiagnostics.registeredOnMainThread)
        XCTAssertEqual(TestTimeoutDiagnostics.registrationCount, 1)
    }

    func testWarningAfterTimeoutDoesNotPublishFailureEvidence() {
        let before = TestTimeoutDiagnostics.publishedReportCount
        TestTimeoutDiagnostics.note("Deliberate timeout followed by a non-failing XCTest warning")
        record(XCTIssue(type: .system, compactDescription: "Diagnostic warning probe", severity: .warning))
        XCTAssertEqual(TestTimeoutDiagnostics.publishedReportCount, before)
    }

    func testCancelledWaitReportsItsFailureMessage() async {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            let options = XCTExpectedFailure.Options()
            options.issueMatcher = { $0.compactDescription.contains("cancelled wait sentinel") }
            XCTExpectFailure("Only the cancelled wait must fail", options: options)
            await TestWait.until(failureMessage: "cancelled wait sentinel") { false }
        }
        await task.value
    }

    func testFinalSynchronousCheckPollsAtDeadline() {
        var polled = false
        let settled = TestWait.until(timeout: .zero, poll: { polled = true }, condition: { polled })
        XCTAssertTrue(settled, "The final check must observe a fresh poll")
    }

    func testTaskWaitTimeoutCancelsCooperativeTarget() async {
        var started = false
        var stopped = false
        let target = Task {
            started = true
            defer { stopped = true }
            try? await Task.sleep(for: .seconds(60))
        }
        do {
            defer { target.cancel() }
            await TestWait.until(failureMessage: "cooperative target did not start") { started }
            let options = XCTExpectedFailure.Options()
            options.issueMatcher = { $0.compactDescription.contains("task timeout sentinel") }
            XCTExpectFailure("Only the bounded task wait must fail", options: options)

            await TestWait.forTask(target, timeout: .milliseconds(1), failureMessage: "task timeout sentinel")

            XCTAssertTrue(target.isCancelled, "A timed-out target must be cancelled")
        }
        await target.value
        XCTAssertTrue(stopped)
    }

    func testCancelledCallerObservesFinishedTargetWithoutCancellingIt() async {
        let target = Task {}
        await target.value
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await TestWait.forTask(target, failureMessage: "finished target was not observed")
        }
        await caller.value
        XCTAssertFalse(target.isCancelled, "Caller cancellation must not cancel a finished target")
    }

    func testCancelledCallerCancelsRunningTarget() async {
        var release: CheckedContinuation<Void, Never>?
        let target = Task { await withCheckedContinuation { release = $0 } }
        await TestWait.until(failureMessage: "target did not start") { release != nil }
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let options = XCTExpectedFailure.Options()
            options.issueMatcher = { $0.compactDescription.contains("caller wait sentinel") }
            XCTExpectFailure("Only the cancelled caller's wait must fail", options: options)
            await TestWait.forTask(target, failureMessage: "caller wait sentinel")
        }
        await caller.value
        XCTAssertTrue(target.isCancelled, "An unfinished target must be cancelled when its caller is cancelled")
        release?.resume()
        await target.value
    }
}
