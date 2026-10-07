import XCTest
@testable import Pensieve

extension ViewChangesViewModelTests {
    func testDuplicatePreviewPathsLoadWithoutTrappingAndKeepFirstFilesNotes() async throws {
        let skill = try fixture.skill("duplicate-paths")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let first = PinnedSkillFileDiff(change: FileTreeChange(path: "SKILL.md", kind: .modified,
            content: .text(old: "old\n", new: "new")), result: UnifiedDiff(old: "old\n", new: "new"))
        let second = PinnedSkillFileDiff(change: FileTreeChange(path: "SKILL.md", kind: .added,
            content: .text(old: "", new: "other\n")), result: UnifiedDiff(old: "", new: "other\n"))
        let preview = PinnedSkillDiff(files: [first, second], unreadFileCount: 0, bytesRead: 12)
        let model = ViewChangesViewModel(library: fixture.library,
            operations: fixture.operations(rows: [row], preview: preview))
        model.open(skillID: skill.id, context: fixture.context)
        await TestWait.until(failureMessage: "Duplicate paths must load without a dictionary trap") { model.state != .loading }
        XCTAssertEqual(model.state, .loaded(preview), "Duplicate paths must not crash preview publication")
        XCTAssertEqual(model.selectedFile, first, "Path selection retains the first matching file")
        XCTAssertEqual(model.lineNotes["SKILL.md"], [[1: ["\\ No newline at end of file"]]],
                       "Duplicate-path notes must correspond to the first selectable file")
    }
}
