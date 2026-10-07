import XCTest
@testable import Pensieve

extension ViewChangesViewModelTests {
    func testDuplicatePreviewPathsLoadWithoutTrappingAndKeepFirstFilesNotes() async throws {
        let skill = try fixture.skill("duplicate-paths")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let first = PinnedSkillFileDiff(change: FileTreeChange(path: "caf\u{00E9}.md", kind: .modified,
            content: .text(old: "old\n", new: "new")), result: UnifiedDiff(old: "old\n", new: "new"))
        let second = PinnedSkillFileDiff(change: FileTreeChange(path: "cafe\u{0301}.md", kind: .added,
            content: .text(old: "", new: "other\n")), result: UnifiedDiff(old: "", new: "other\n"))
        let preview = PinnedSkillDiff(files: [first, second], unreadFileCount: 0, bytesRead: 12)
        let model = ViewChangesViewModel(library: fixture.library,
            operations: fixture.operations(rows: [row], preview: preview))
        model.open(skillID: skill.id, context: fixture.context)
        await TestWait.until(failureMessage: "Duplicate paths must load without a dictionary trap") { model.state != .loading }
        XCTAssertEqual(model.state, .loaded(preview), "Duplicate paths must not crash preview publication")
        XCTAssertEqual(model.files.count, 2, "Canonically equal paths must both be listed")
        XCTAssertEqual(model.files.map { Array($0.path.utf8) }, [Array(first.path.utf8), Array(second.path.utf8)])
        XCTAssertEqual(model.selectedFile, first, "The first file is initially selected")
        XCTAssertEqual(model.selectedFileNotes, [[1: ["\\ No newline at end of file"]]],
                       "Duplicate-path notes must correspond to the first selectable file")
        model.selectFile(id: 1)
        XCTAssertEqual(model.selectedFile?.diff, second.diff, "Each canonically equal path must select its own diff")
        XCTAssertEqual(model.selectedFileNotes, [[:]], "Each canonically equal path must show its own notes")
        model.selectFile(id: 0)
        XCTAssertEqual(model.selectedFile?.diff, first.diff)
    }
}
