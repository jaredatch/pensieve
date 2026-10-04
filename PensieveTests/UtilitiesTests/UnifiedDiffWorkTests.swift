import XCTest
@testable import Pensieve

final class UnifiedDiffWorkTests: XCTestCase {
    func testDiffPastWorkBoundHasNoCountsAndWorstCaseStaysWithinFiveTimesBenign() throws {
        // A small adversarial pair exposes the missing bound without hanging an old implementation
        // on the 209,715-line fixture. The same test reaches the full-size timing after that guard.
        let canary = preview(old: String(repeating: "aaaa\n", count: 1_600),
                             new: String(repeating: "bbbb\n", count: 1_600))
        guard canary.files.first?.content == .tooLarge else {
            XCTFail("The adversarial pair must hit the named diff work bound")
            return
        }
        XCTAssertNil(canary.files.first?.diff)
        XCTAssertNil(canary.files.first?.linesAdded)
        XCTAssertNil(canary.files.first?.linesRemoved)
        let old = String(repeating: "aaaa\n", count: 1_048_576 / 5)
        let benign = "bbbb\n" + old.dropFirst(5)
        let start = Date()
        let ordinary = preview(old: old, new: benign)
        let baseline = Date().timeIntervalSince(start)
        XCTAssertEqual(ordinary.files.first?.linesAdded, 1)
        XCTAssertEqual(ordinary.files.first?.linesRemoved, 1)
        let hardStart = Date()
        let hard = preview(old: old, new: String(repeating: "bbbb\n", count: 1_048_576 / 5))
        let adversarial = Date().timeIntervalSince(hardStart)
        XCTAssertEqual(hard.files.first?.content, .tooLarge)
        XCTAssertNil(hard.files.first?.linesAdded)
        XCTAssertLessThanOrEqual(adversarial, baseline * 5)
        let receipt = "DIFF_WORK_TIMING benign=\(baseline) adversarial=\(adversarial) bytes=\(old.utf8.count)"
        XCTContext.runActivity(named: receipt) { _ in }
        print(receipt)
        try PreviewResourceTestEvidence.record("diff", message: receipt)
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

    private func preview(old: String, new: String) -> PinnedSkillDiff {
        PinnedSkillDiff(comparison: FileTreeComparison(changes: [FileTreeChange(
            path: "many-lines", kind: .modified, content: .text(old: old, new: new)
        )], unreadFileCount: 0, bytesRead: old.utf8.count + new.utf8.count))
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
