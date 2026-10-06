import SwiftData
import XCTest
@testable import Pensieve

extension ViewChangesViewModelTests {
    func testPresentationMakesHiddenLineAndFilenameScalarsVisible() throws {
        let values: [UInt32] = [13, 0x85, 0x2028, 0x2029] + Array(0x202A...0x202E)
            + Array(0x2066...0x2069) + Array(0xE0000...0xE007F)
        for value in values {
            let scalar = try XCTUnwrap(Unicode.Scalar(value))
            let mark = value == 13 ? "␍" : String(format: "⟨U+%04X⟩", value)
            let line = UnifiedDiffLine(kind: .added, text: "before" + String(scalar) + "after\n",
                                       oldLineNumber: nil, newLineNumber: 1)
            XCTAssertEqual(ViewChangesPresentation.lineText(line), "before" + mark + "after",
                           "Hidden scalars must remain visible in the exact presentation rendered by the diff")
        }
        for (path, visible) in [("folder/evil\u{202E}.txt", "evil⟨U+202E⟩.txt"),
                                ("folder/first\nlast", "first⟨U+000A⟩last"),
                                ("folder/tab\tname", "tab⟨U+0009⟩name")] {
            let file = try XCTUnwrap(PinnedSkillDiff.build(comparison: FileTreeComparison(changes: [
                FileTreeChange(path: path, kind: .added, content: .binary)
            ], unreadFileCount: 0, bytesRead: 0)).files.first)
            XCTAssertEqual(ViewChangesPresentation.filePath(file), "folder/" + visible,
                           "The file header must use the same visible marks as its sidebar")
            XCTAssertEqual(ViewChangesPresentation.accessibilityLabel(file), visible + ", folder, Binary file",
                           "Filename controls must be visible in the sidebar and header presentation")
        }
    }

    func testReopeningTheSameLoadedIdentityDoesNotReloadPreview() async throws {
        let skill = try fixture.skill("same-preview")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let calls = UpdateReviewRecorder<UUID>()
        let model = ViewChangesViewModel(library: fixture.library,
            operations: fixture.operations(rows: [row], diff: { request, _ in
                calls.append(request.id)
                return UpdateReviewFixture.preview()
            }))
        model.open(skillID: skill.id, context: fixture.context)
        await TestWait.until(failureMessage: "initial preview did not finish") { model.state != .loading }
        model.selectFile(path: "scripts/setup.sh")
        let loaded = model.state
        model.open(skillID: skill.id, context: fixture.context)
        XCTAssertEqual(model.state, loaded, "Opening a loaded unchanged identity must only bring its window forward")
        await TestWait.until(failureMessage: "reopened preview did not finish") { model.state != .loading }
        XCTAssertEqual(calls.values, [skill.id], "A loaded unchanged preview must not clone again")
        XCTAssertEqual(model.selectedFilePath, "scripts/setup.sh")
        skill.updatedAt = skill.updatedAt.addingTimeInterval(1)
        model.open(skillID: skill.id, context: fixture.context)
        await TestWait.until(failureMessage: "changed preview did not finish") { model.state != .loading }
        XCTAssertEqual(calls.values, [skill.id, skill.id], "Changed identities still need a fresh preview")
    }
    func testWindowRecheckWaitsForSheetAndKeepsItsApplyOrRecheckResult() async throws {
        for apply in [true, false] {
            let skill = try fixture.skill(apply ? "busy-apply" : "busy-check")
            let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
            let applied = try appliedCompletion(skill: skill, row: row)
            let started = DispatchSemaphore(value: 0)
            let release = TestWait.Gate(owner: self)
            let checks = UpdateReviewRecorder<UUID>()
            let diffs = UpdateReviewRecorder<String>()
            let newCommit = String(repeating: "4", count: 40)
            let sheet = blockedSheet(row: row, applied: applied, started: started, release: release, commit: newCommit)
            let window = ViewChangesViewModel(library: fixture.library,
                operations: fixture.operations(rows: [row], diff: { request, _ in
                    diffs.append(request.upstreamCommit)
                    if diffs.values.count == 1 { throw SkillUpdateFlowError.repositoryChanged }
                    return UpdateReviewFixture.preview()
                }, recheck: { id, _ in
                    checks.append(id)
                    return UpdatesViewModelTests.refreshedRecheckCompletion(row: row, skillID: id)
                }), updates: sheet)
            sheet.present(library: fixture.library)
            await sheet.loadAndReport(context: fixture.context)
            window.open(skillID: skill.id, context: fixture.context)
            await TestWait.until(failureMessage: "preview failure did not arrive") { window.state != .loading }
            if apply { sheet.applySelected(context: fixture.context) } else { sheet.recheck(row, context: fixture.context) }
            let task = try XCTUnwrap(sheet.operationTask)
            let didStart = await TestWait.forSemaphore(started)
            XCTAssertTrue(didStart)
            window.recheck(context: fixture.context)
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertTrue(checks.values.isEmpty, "The window must hold Re-check while the sheet's worker is blocked")
            XCTAssertTrue(window.isRechecking)
            release.open()
            await TestWait.forTask(task, failureMessage: "sheet worker did not finish")
            await TestWait.until(failureMessage: "held window check did not settle") { !window.isRechecking }
            XCTAssertTrue(checks.values.isEmpty, "The sheet's completed result must remain authoritative")
            XCTAssertEqual(skill.updateAvailable, !apply)
            XCTAssertEqual(skill.upstreamCommit, apply ? nil : newCommit)
            XCTAssertEqual(skill.upstreamTree, apply ? nil : "sheet-tree")
            if apply { XCTAssertEqual(window.state, .stale("This skill was updated.")) } else {
                await TestWait.until(failureMessage: "the sheet pin did not reload") { window.state != .loading }
                XCTAssertEqual(window.row?.upstreamCommit, newCommit)
                XCTAssertNotNil(window.selectedFile)
            }
        }
    }

    private func blockedSheet(row: UpdatesRow, applied: SkillUpdateCompletion, started: DispatchSemaphore,
                              release: TestWait.Gate, commit: String) -> UpdatesViewModel {
        UpdatesViewModel(rowLoader: { _ in [row] }, applyOperation: { _, _, _, _, _, _ in
            started.signal()
            try release.wait()
            return applied
        }, recheckOperation: { id, _ in
            started.signal()
            try release.wait()
            return SkillUpdateRecheckCompletion(row: row, skillID: id, updateAvailable: true,
                lastCheckedAt: Date(), lastCheckedHead: commit, upstreamTree: "sheet-tree",
                upstreamCommit: commit, upstreamCommitDate: row.updateDate, checkError: nil)
        })
    }

    private func appliedCompletion(skill: Skill, row: UpdatesRow) throws -> SkillUpdateCompletion {
        var origin = try XCTUnwrap(skill.installedOrigin)
        origin.installedCommit = row.upstreamCommit
        origin.installedTree = row.upstreamTree
        return SkillUpdateCompletion(skillID: skill.id, name: skill.name, skillDescription: skill.skillDescription,
            installedOriginData: try JSONEncoder().encode(origin), updatedAt: Date())
    }

}
