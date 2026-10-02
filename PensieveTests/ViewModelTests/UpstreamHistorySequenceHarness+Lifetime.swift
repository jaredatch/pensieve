import XCTest

@MainActor
extension UpstreamHistorySequenceHarness {
    /// Report before cleanup: an uncooperative request must never hide the original schedule error.
    func checkRun(
        file: StaticString = #filePath,
        line: UInt = #line,
        report: @MainActor (String) -> Void = { XCTFail($0) },
        body: @MainActor () async throws -> Void
    ) async -> Bool {
        do {
            try await body()
            await close(file: file, line: line)
            return !cleanupFailed
        } catch {
            report(String(describing: error))
            await close(file: file, line: line)
            return false
        }
    }

    /// Aborts gates and gives pending tasks one bounded opportunity to finish. The join is
    /// unstructured so ignoring cancellation cannot extend the caller's cleanup deadline.
    /// Giving up always records an XCTest failure, including after a successful replay.
    func close(file: StaticString = #filePath, line: UInt = #line) async {
        abort()
        let pending = tasks
        let completion = frontier
        var joined = false
        let join = Task {
            for task in pending { await task.value }
            joined = true
            completion.notify()
        }
        let outcome = await completion.wait(timeout: cleanupTimeout) { joined && self.workers.isEmpty }
        if outcome != .satisfied {
            if outcome == .timedOut { recordTimeout("cleanup; joined=\(joined)") }
            cleanupFailed = true
            pending.forEach { $0.cancel() }
            join.cancel()
            let reason = outcome == .cancelled ? "Cancelled" : "Timed out"
            cleanupReport("\(reason) waiting for cleanup; scenario: \(scenario); schedule: \(scheduled)", file, line)
        }
    }
}
