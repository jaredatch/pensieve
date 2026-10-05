import XCTest
@testable import Pensieve

final class UnifiedDiffWorkTests: XCTestCase {
    func testDiffPastWorkBoundHasNoCountsAndWorstCaseStaysWithinFiveTimesBenign() throws {
        let maximumLines = 1_048_576 / 5
        let old = String(repeating: "aaaa\n", count: maximumLines)
        let changed = "bbbb\n" + old.dropFirst(5)
        let references = try referenceTimings(old: old, new: changed)
        let reference = references.sorted { $0.seconds < $1.seconds }[references.count / 2]
        let baseline = reference.seconds
        var receipts = ["DIFF_REFERENCE bytes=\(old.utf8.count) work=\(reference.work) seconds=\(baseline)"]
        receipts += references.enumerated().map {
            "DIFF_REFERENCE_SAMPLE index=\($0.offset) work=\($0.element.work) seconds=\($0.element.seconds)"
        }
        var worst = 0.0
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
            worst = max(worst, elapsed)
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
        XCTAssertLessThanOrEqual(worst, baseline * 5, "The sweep worst must fit five times the median reference")
        receipts.append("DIFF_WORST seconds=\(worst) medianReference=\(baseline) ratio=\(worst / baseline)")
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

    func testSharedDiffBudgetExhaustionHasItsOwnReasonAndKeepsPathsKindsWithoutCounts() throws {
        let changes: [FileTreeChange] = [
            FileTreeChange(path: "added", kind: .added, content: .text(old: "", new: "new\n")),
            FileTreeChange(path: "modified", kind: .modified, content: .text(old: "old\n", new: "new\n")),
            FileTreeChange(path: "removed", kind: .removed, content: .text(old: "old\n", new: "")),
            FileTreeChange(path: "size", kind: .modified, content: .tooLarge),
            FileTreeChange(path: "binary", kind: .added, content: .binary)
        ]
        let budget = BoundedLineDifference.WorkBudget(maximumWork: 0)
        let result = try PinnedSkillDiff.build(comparison: FileTreeComparison(
            changes: changes, unreadFileCount: 0, bytesRead: 23), budget: budget)
        XCTAssertEqual(result.files.map(\.path), changes.map(\.path))
        XCTAssertEqual(result.files.map(\.kind), changes.map(\.kind))
        for file in result.files.prefix(3) {
            XCTAssertEqual(file.content, .diffBudgetExhausted, "Budget exhaustion must differ from the size bound")
            XCTAssertNil(file.diff)
            XCTAssertNil(file.linesAdded)
            XCTAssertNil(file.linesRemoved)
        }
        XCTAssertEqual(result.files[3].content, .tooLarge)
        XCTAssertEqual(result.files[4].content, .binary)
        // A search that spends the last shared units uses that reason too.
        let limited = try PinnedSkillDiff.build(comparison: FileTreeComparison(
            changes: [changes[1]], unreadFileCount: 0, bytesRead: 8),
            budget: .init(maximumWork: 2))
        XCTAssertEqual(limited.files.first?.content, .diffBudgetExhausted)
        XCTAssertNil(limited.files.first?.linesAdded)
    }

    func testFourPerFileWorkRefusalsKeepTooLargeWhenFourthEmptiesSharedBudget() throws {
        let budget = BoundedLineDifference.WorkBudget(maximumWork: PinnedSkillDiff.maximumDiffWork)
        let result = try PinnedSkillDiff.build(comparison: comparison(count: 4, lines: 4_100), budget: budget)
        XCTAssertEqual(budget.consumed, PinnedSkillDiff.maximumDiffWork)
        XCTAssertEqual(result.files.count, 4)
        for file in result.files {
            XCTAssertEqual(file.content, .tooLarge,
                           "The per-file cap limits each rewrite, including the fourth that empties the shared budget")
            XCTAssertNil(file.diff)
            XCTAssertNil(file.linesAdded)
            XCTAssertNil(file.linesRemoved)
        }
    }

    func testSharedBudgetExhaustionSkipsLinePreparationAndKeyHashing() throws {
        let change = FileTreeChange(path: "later", kind: .modified,
                                    content: .text(old: "old\n", new: "new\n"))
        var preparations = 0
        let file = PinnedSkillFileDiff(change: change, budget: .init(maximumWork: 0)) { old, new in
            preparations += 1
            return UnifiedDiff(old: old, new: new)
        }
        XCTAssertEqual(preparations, 0, "An exhausted preview must skip the entire text preparation")
        XCTAssertEqual(file.content, .diffBudgetExhausted)
        XCTAssertNil(file.linesAdded)
        XCTAssertNil(file.linesRemoved)
    }

    func testPreviewSharesWorkBudgetAndOrdinaryMultiFileDiffsRemainComplete() throws {
        try assertSharedPreviewWorkBound()
    }

    private func assertSharedPreviewWorkBound() throws {
        let references = try referenceTimings(old: String(repeating: "aaaa\n", count: 4_100),
                                             new: String(repeating: "bbbb\n", count: 4_100), expectedCount: nil)
        let oneBudgetTime = references.map(\.seconds).sorted()[references.count / 2]
        let hard = comparison(count: 1_000, lines: 3_200)
        var finishedWork = 0
        var currentWork = 0
        let began = Date()
        let budget = BoundedLineDifference.WorkBudget(maximumWork: PinnedSkillDiff.maximumDiffWork)
        let preview = try PinnedSkillDiff.build(comparison: hard, budget: budget) { work in
            if work == 0, currentWork > 0 { finishedWork += currentWork; currentWork = 0 }
            currentWork = max(currentWork, work)
            if finishedWork + currentWork > PinnedSkillDiff.maximumDiffWork + BoundedLineDifference.maximumWork {
                XCTFail("One preview must stop at its shared work budget")
                throw DiffWorkWatchdog.exceeded
            }
        }
        let elapsed = Date().timeIntervalSince(began)
        let budgetRatio = Double(PinnedSkillDiff.maximumDiffWork) / Double(BoundedLineDifference.maximumWork)
        XCTAssertLessThanOrEqual(elapsed, oneBudgetTime * (budgetRatio + 2))
        XCTAssertEqual(budget.consumed, PinnedSkillDiff.maximumDiffWork, "One preview spends exactly its shared budget")
        XCTAssertEqual(preview.files.count, 1_000)
        XCTAssertEqual(preview.files.first?.linesAdded, 3_200)
        for file in preview.files.suffix(990) {
            XCTAssertEqual(file.content, .diffBudgetExhausted)
            XCTAssertNil(file.diff)
            XCTAssertNil(file.linesAdded)
            XCTAssertNil(file.linesRemoved)
        }
        let ordinaryBudget = BoundedLineDifference.WorkBudget(maximumWork: PinnedSkillDiff.maximumDiffWork)
        let ordinary = try PinnedSkillDiff.build(comparison: comparison(count: 9, lines: 2_500),
                                                budget: ordinaryBudget)
        XCTAssertEqual(ordinary.files.count, 9)
        XCTAssertTrue(ordinary.files.allSatisfy { $0.linesAdded == 2_500 && $0.linesRemoved == 2_500 })
        let receipt = "PREVIEW_WORK files=1000 budget=\(PinnedSkillDiff.maximumDiffWork) seconds=\(elapsed) "
            + "singleBudgetSeconds=\(oneBudgetTime) ordinaryFiles=9 ordinaryWork=\(ordinaryBudget.consumed)"
        let samples = references.enumerated().map {
            "PREVIEW_REFERENCE_SAMPLE index=\($0.offset) work=\($0.element.work) seconds=\($0.element.seconds)"
        }
        let evidence = ([receipt] + samples).joined(separator: "\n")
        print(evidence)
        try PreviewResourceTestEvidence.record("preview", message: evidence)
    }

    func testMiddleSnakeNeverCrossesAWorkLimitBetweenCheckpoints() throws {
        for limit in 1...24 {
            let budget = BoundedLineDifference.WorkBudget(maximumWork: limit)
            let edits = try BoundedLineDifference.compute(before: ["old\n"], after: ["new\n"],
                                                        budget: budget) { _ in }
            XCTAssertLessThanOrEqual(budget.consumed, limit, "Every charge must respect the exact remaining budget")
            if limit < 7 { XCTAssertNil(edits, "A middle-snake search starting at the cap must refuse") }
            if limit == 7 { XCTAssertEqual(edits?.added.count, 1, "Finishing exactly at the cap is allowed") }
        }
    }

    func testFinishedDiffDoesNotCallATrailingWorkCheckpoint() {
        var edits: BoundedLineDifference.Edits?
        XCTAssertNoThrow(edits = try BoundedLineDifference.compute(before: ["old\n"], after: ["new\n"]) { work in
            if work > 0 { throw CancellationError() }
        }, "A finished small search must not be cancelled by a redundant trailing checkpoint")
        XCTAssertEqual(edits?.added.count, 1)
        XCTAssertEqual(edits?.removed.count, 1)
    }

    private func comparison(count: Int, lines: Int) -> FileTreeComparison {
        let before = String(repeating: "aaaa\n", count: lines)
        let after = String(repeating: "bbbb\n", count: lines)
        return FileTreeComparison(changes: (0..<count).map {
            FileTreeChange(path: "file\($0)", kind: .modified, content: .text(old: before, new: after))
        }, unreadFileCount: 0, bytesRead: count * lines * 10)
    }

    private func referenceTimings(old: String, new: String,
                                  expectedCount: Int? = 1) throws -> [(seconds: TimeInterval, work: Int)] {
        try (0..<5).map { _ in
            let start = Date()
            let ordinary = try measuredPreview(old: old, new: new)
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertEqual(ordinary.preview.files.first?.linesAdded, expectedCount)
            XCTAssertEqual(ordinary.preview.files.first?.linesRemoved, expectedCount)
            return (elapsed, ordinary.work)
        }
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
        let budget = BoundedLineDifference.WorkBudget(maximumWork: PinnedSkillDiff.maximumDiffWork)
        let preview = try PinnedSkillDiff.build(comparison: FileTreeComparison(changes: [FileTreeChange(
            path: "many-lines", kind: .modified, content: .text(old: old, new: new)
        )], unreadFileCount: 0, bytesRead: old.utf8.count + new.utf8.count), budget: budget)
        return (preview, budget.consumed)
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

private enum DiffWorkWatchdog: Error { case exceeded }
