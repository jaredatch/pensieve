import XCTest
@testable import Pensieve

extension UnifiedDiffWorkTests {
    func testOversizedOutputFileLeavesRoomForLaterSmallDiffs() throws {
        let changes = [
            FileTreeChange(path: "00-huge", kind: .added, content: .text(old: "", new: String(repeating: "\n", count: 70_000))),
            FileTreeChange(path: "SKILL.md", kind: .modified, content: .text(old: "old\n", new: "new\n")),
            FileTreeChange(path: "scripts/small", kind: .added, content: .text(old: "", new: "echo hello\n"))
        ]
        let preview = try PinnedSkillDiff.build(comparison: FileTreeComparison(
            changes: changes, unreadFileCount: 0, bytesRead: 70_025))
        XCTAssertEqual(ViewChangesPresentation.unavailableReason(preview.files[0]), "This file's diff is too large to show",
                       "One oversized file must have its own reason, not claim the whole preview bound is spent")
        XCTAssertNil(preview.files[0].diff)
        XCTAssertEqual(preview.files[1].linesAdded, 1, "An unrendered huge file must leave output room for SKILL.md")
        XCTAssertEqual(preview.files[2].linesAdded, 1, "Later small scripts must still render")
        let shared = try PinnedSkillDiff.build(comparison: FileTreeComparison(changes: [
            FileTreeChange(path: "first", kind: .added, content: .text(old: "", new: String(repeating: "\n", count: 40_000))),
            FileTreeChange(path: "second", kind: .added, content: .text(old: "", new: String(repeating: "\n", count: 30_000))),
            changes[1]
        ], unreadFileCount: 0, bytesRead: 70_008))
        XCTAssertEqual(shared.files[1].content, .diffOutputBoundReached,
                       "A file that fits alone must name the shared output bound when earlier files used its room")
        XCTAssertNil(shared.files[1].diff)
        XCTAssertEqual(shared.files[2].linesAdded, 1, "A refused shared-bound file retains no output allowance")
    }

    func testDiffRowsAndHunksSpendTheSharedWorkBudget() throws {
        let change = FileTreeChange(path: "text", kind: .modified, content: .text(old: "old\n", new: "new\n"))
        let budget = BoundedLineDifference.WorkBudget(maximumWork: 17)
        let preview = try PinnedSkillDiff.build(comparison: FileTreeComparison(
            changes: [change], unreadFileCount: 0, bytesRead: 8), budget: budget)
        XCTAssertEqual(preview.files.first?.content, .diffBudgetExhausted,
                       "Row and hunk emission must spend the preview's remaining shared work")
        XCTAssertNil(preview.files.first?.diff)
        XCTAssertEqual(budget.consumed, 17)
    }

    func testOneSidedRunsSpendTheSharedWorkBudget() throws {
        for added in [true, false] {
            let lines = Array(repeating: "\n", count: 18)
            let budget = BoundedLineDifference.WorkBudget(maximumWork: 17)
            let edits = try BoundedLineDifference.compute(before: added ? [] : lines, after: added ? lines : [],
                                                        budget: budget) { _ in }
            XCTAssertNil(edits, "A one-sided run must refuse when its work exceeds the shared budget")
            XCTAssertEqual(budget.consumed, 17, "Every emitted one-sided edit must spend work")
        }
    }

    func testThirtyOneNewlineFilesStayWithinThePreviewOutputBound() throws {
        let bound = 65_536
        let text = String(repeating: "\n", count: bound / 4)
        for added in [true, false] {
            let changes = (0..<31).map {
                FileTreeChange(path: "file\($0)", kind: added ? .added : .removed,
                               content: .text(old: added ? "" : text, new: added ? text : ""))
            }
            let preview = try PinnedSkillDiff.build(comparison: FileTreeComparison(
                changes: changes, unreadFileCount: 0, bytesRead: text.utf8.count * 31))
            let retained = preview.files.compactMap(\.diff).flatMap(\.hunks).reduce(0) { $0 + $1.lines.count }
            XCTAssertLessThanOrEqual(retained, bound, "Retained preview lines must stay within the named output bound")
            XCTAssertEqual(preview.files.count, 31)
            XCTAssertEqual(preview.files.first?.linesAdded, added ? bound / 4 : 0)
            for file in preview.files.suffix(27) {
                XCTAssertNil(file.diff, "Files after the output bound must retain only their change listing")
                XCTAssertNil(file.linesAdded)
                XCTAssertTrue(ViewChangesPresentation.unavailableReason(file)?.contains("output bound") == true)
            }
        }
    }
}
