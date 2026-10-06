import Foundation
import XCTest

private let defaultTestWaitTimeout: Duration = .seconds(TestWait.timeoutSeconds)

enum TestWait {
    static let timeoutSeconds: TimeInterval = 30

    // Cold AppKit/SwiftUI hosts and OCR can exceed three seconds on CI. Only first-render
    // readiness gets this bounded allowance; subsequent interaction waits keep their own deadlines.
    static let firstRenderTimeoutSeconds: TimeInterval = 15

    @MainActor
    static func until(
        timeout: Duration = defaultTestWaitTimeout,
        pollInterval: Duration = .milliseconds(10),
        failureMessage: String,
        diagnostics: () -> String = { "" },
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            guard !Task.isCancelled else { break }
            do {
                try await Task.sleep(for: pollInterval)
            } catch is CancellationError {
                break
            } catch {
                XCTFail("\(failureMessage): \(error.localizedDescription)")
                return
            }
        }
        if condition() { return }
        if !Task.isCancelled {
            TestTimeoutDiagnostics.note("TestWait.until: \(failureMessage); condition=false; \(diagnostics())")
        }
        XCTFail(failureMessage)
    }

    /// Bounds observation of a raw task without adding a production completion hook. Success
    /// joins the observer, leaving no helper task behind. The observer gets a MainActor turn
    /// before cancellation is judged. An unfinished wait fails here and cancels the target and
    /// observer, whether timeout or caller cancellation ended it. An observed completion avoids
    /// cancellation. If the target finishes before its observer records it, cancellation may
    /// still be requested; cancelling an already-finished task has no effect. A cooperative
    /// target ends; an uncooperative target can retain its observer until it ends.
    /// The observer never reports XCTest issues, including after the owning test has finished.
    @MainActor
    static func forTask(
        _ task: Task<Void, Never>,
        timeout: Duration = defaultTestWaitTimeout,
        failureMessage: String
    ) async {
        var finished = false
        var observer: Task<Void, Never>?
        await withCheckedContinuation { ready in
            observer = Task {
                ready.resume()
                await task.value
                finished = true
            }
        }
        await until(timeout: timeout, failureMessage: failureMessage, diagnostics: {
            "targetCancelled=\(task.isCancelled); observerFinished=\(finished); " +
                "observerCancelled=\(observer?.isCancelled == true)"
        }, { finished })
        if finished {
            await observer?.value
        } else {
            task.cancel()
            observer?.cancel()
        }
    }

    static func forSemaphore(
        _ semaphore: DispatchSemaphore,
        timeout: Duration = defaultTestWaitTimeout
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if semaphore.wait(timeout: .now()) == .success { return true }
            guard !Task.isCancelled else { return false }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
        }
        if semaphore.wait(timeout: .now()) == .success { return true }
        TestTimeoutDiagnostics.note("TestWait.forSemaphore: no permit before deadline; callerCancelled=\(Task.isCancelled)")
        return false
    }

    @MainActor
    static func until(
        timeout: Duration = defaultTestWaitTimeout,
        poll: () -> Void,
        condition: () -> Bool
    ) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            guard !Task.isCancelled else { return false }
            poll()
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        poll()
        if condition() { return true }
        TestTimeoutDiagnostics.note("TestWait.until synchronous: condition=false after final poll")
        return false
    }
}
