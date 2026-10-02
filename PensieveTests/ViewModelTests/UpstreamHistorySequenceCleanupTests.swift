import XCTest
@testable import Pensieve

@MainActor
final class UpstreamHistorySequenceCleanupTests: UpstreamHistoryCacheTestCase {
    func testCleanupTimeoutIsAnXCTestFailureOnTheSuccessPath() async {
        let flow = UpstreamHistorySequenceHarness()
        flow.cleanupTimeout = .milliseconds(20)
        flow.timeoutThreadSample = { nil } // Deliberate timeout: keep the real failure assertions, omit sampling.
        var held: CheckedContinuation<Void, Never>?
        flow.enqueue("stuck") { await withCheckedContinuation { held = $0 } }
        flow.abort()
        await TestWait.until(failureMessage: "Request did not reach its hold") { held != nil }
        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        options.issueMatcher = { $0.compactDescription.contains("Timed out waiting for cleanup") }
        XCTExpectFailure("Cleanup cannot silently abandon a request", options: options)
        await flow.close()
        XCTAssertNotNil(held)
        held?.resume()
        for task in flow.tasks { await task.value }
        await flow.close()
    }

    func testCancelledFrontierNamesCancellationInsteadOfTimeout() async {
        let flow = UpstreamHistorySequenceHarness()
        flow.lanes["cancelled"] = .running
        var message = ""
        let waiter = Task {
            do { try await flow.settle() } catch { message = String(describing: error) }
        }
        await TestWait.until(failureMessage: "Frontier did not register") { flow.frontierChecks > 0 }
        waiter.cancel()
        await waiter.value
        XCTAssertTrue(message.contains("Cancelled waiting for frontier"), message)
        XCTAssertFalse(message.contains("Timed out"), message)
        XCTAssertTrue(message.contains("schedule:"), message)
        await flow.close()
    }
}
