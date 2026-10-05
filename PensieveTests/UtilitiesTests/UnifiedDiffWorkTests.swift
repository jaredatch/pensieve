import XCTest
@testable import Pensieve

final class UnifiedDiffWorkTests: XCTestCase {
    func testDiffPastWorkBoundHasNoCountsAndWorstCaseStaysWithinFiveTimesBenign() throws {
        let maximumLines = 1_048_576 / 5
        let old = String(repeating: "aaaa\n", count: maximumLines)
        let start = Date()
        let ordinary = try measuredPreview(old: old, new: "bbbb\n" + old.dropFirst(5))
        let baseline = Date().timeIntervalSince(start)
        XCTAssertEqual(ordinary.preview.files.first?.linesAdded, 1)
        XCTAssertEqual(ordinary.preview.files.first?.linesRemoved, 1)
        var receipts = ["DIFF_REFERENCE bytes=\(old.utf8.count) work=\(ordinary.work) seconds=\(baseline)"]
        var samples: [Int: Bool] = [:]
        func measure(_ count: Int) throws -> Bool {
            if let result = samples[count] { return result }
            let before = String(repeating: "aaaa\n", count: count)
            let after = String(repeating: "bbbb\n", count: count)
            let began = Date()
            let sample = try measuredPreview(old: before, new: after)
            let elapsed = Date().timeIntervalSince(began)
            let file = try XCTUnwrap(sample.preview.files.first)
            let refused = file.content == .tooLarge
            if refused {
                XCTAssertNil(file.diff)
                XCTAssertNil(file.linesAdded)
                XCTAssertNil(file.linesRemoved)
            } else {
                XCTAssertEqual(file.linesAdded, count)
                XCTAssertEqual(file.linesRemoved, count)
            }
            XCTAssertLessThanOrEqual(elapsed, baseline * 5, "all-different \(count) lines, work \(sample.work)")
            receipts.append("DIFF_SWEEP lines=\(count) bytes=\(count * 5) work=\(sample.work) "
                            + "seconds=\(elapsed) refused=\(refused)")
            samples[count] = refused
            return refused
        }
        let (lower, upper) = try findBudgetCrossing(maximumLines: maximumLines, measure: measure)
        receipts.append("DIFF_BUDGET_CROSSING lastFull=\(lower) firstRefused=\(upper) "
                        + "budget=\(BoundedLineDifference.maximumWork)")
        var count = upper
        while count < maximumLines {
            count = min(maximumLines, count * 2)
            XCTAssertTrue(try measure(count))
        }
        try recordSweep(receipts)
    }

    func testCancellingPreviewStopsAtAMidDiffCheckpoint() async throws {
        let old = String(repeating: "aaaa\n", count: 1_048_576 / 5)
        let comparison = FileTreeComparison(changes: [FileTreeChange(
            path: "many-lines", kind: .modified, content: .text(old: old, new: "bbbb\n" + old.dropFirst(5))
        )], unreadFileCount: 0, bytesRead: 0)
        let reached = expectation(description: "inside the edit search")
        let resume = DispatchSemaphore(value: 0)
        let progress = DiffWorkProgress()
        let task = Task.detached {
            try PinnedSkillDiff.build(comparison: comparison) { work in
                if work > 0, progress.record(work) == 1 {
                    reached.fulfill()
                    XCTAssertEqual(resume.wait(timeout: .now() + 10), .success)
                }
            }
        }
        await fulfillment(of: [reached], timeout: 10)
        task.cancel()
        resume.signal()
        do {
            _ = try await task.value
            XCTFail("A preview cancelled inside the diff must throw CancellationError")
        } catch is CancellationError {
            XCTAssertEqual(progress.count, 1, "No further search checkpoint after cancellation")
            XCTAssertGreaterThan(progress.work, 0)
        }
        let receipt = "CANCEL_DIFF work=\(progress.work) checkpoints=\(progress.count)"
        XCTContext.runActivity(named: receipt) { _ in }
        print(receipt)
        try PreviewResourceTestEvidence.record("cancellation", message: receipt)
    }

    private func findBudgetCrossing(maximumLines: Int, measure: (Int) throws -> Bool) throws -> (Int, Int) {
        var lower = 0
        var upper = 1
        while upper < maximumLines, try !measure(upper) {
            lower = upper
            upper = min(maximumLines, upper * 2)
        }
        XCTAssertTrue(try measure(upper), "The sweep must reach the actual work budget")
        while upper - lower > 1 {
            let middle = lower + (upper - lower) / 2
            if try measure(middle) { upper = middle } else { lower = middle }
        }
        return (lower, upper)
    }

    private func recordSweep(_ receipts: [String]) throws {
        let receipt = receipts.joined(separator: "\n")
        XCTContext.runActivity(named: receipt) { _ in }
        print(receipt)
        try PreviewResourceTestEvidence.record("diff", message: receipt)
    }

    private func measuredPreview(old: String, new: String) throws -> (preview: PinnedSkillDiff, work: Int) {
        var charged = 0
        let preview = try PinnedSkillDiff.build(comparison: FileTreeComparison(changes: [FileTreeChange(
            path: "many-lines", kind: .modified, content: .text(old: old, new: new)
        )], unreadFileCount: 0, bytesRead: old.utf8.count + new.utf8.count)) { charged = max(charged, $0) }
        return (preview, charged)
    }
}

private final class DiffWorkProgress {
    private let lock = NSLock()
    private var values: [Int] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    var work: Int { lock.lock(); defer { lock.unlock() }; return values.first ?? 0 }
    func record(_ work: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        values.append(work)
        return values.count
    }
}
