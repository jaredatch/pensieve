import SwiftData
import XCTest
@testable import Pensieve

extension ViewChangesViewModelTests {
    func testSheetApplyAndRecheckAreUnavailableDuringTheWindowsSameSkillRecheck() async throws {
        let skill = try fixture.skill("reverse-race")
        let other = try fixture.skill("reverse-unrelated")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let otherRow = try UpdatesViewModel.makeRow(skill: other, driftedLocally: false)
        let started = DispatchSemaphore(value: 0)
        let release = TestWait.Gate(owner: self)
        let applied = UpdateReviewRecorder<UUID>()
        let checked = UpdateReviewRecorder<UUID>()
        let completion = try appliedCompletion(skill: skill, row: row)
        let sheet = reverseSheet(rows: [row, otherRow], completion: completion, applied: applied, checked: checked)
        let window = ViewChangesViewModel(library: fixture.library,
            operations: fixture.operations(rows: [row], diff: { _, _ in throw SkillUpdateFlowError.repositoryChanged },
                recheck: { id, _ in
                    started.signal()
                    try release.wait()
                    return SkillUpdateRecheckCompletion(row: row, skillID: id, updateAvailable: true,
                        lastCheckedAt: Date(), lastCheckedHead: row.upstreamCommit, upstreamTree: row.upstreamTree,
                        upstreamCommit: row.upstreamCommit, upstreamCommitDate: row.updateDate, checkError: nil)
                }), updates: sheet)
        sheet.present(library: fixture.library)
        await sheet.loadAndReport(context: fixture.context)
        sheet.selectedSkillIDs = [skill.id]
        sheet.statuses[skill.id] = .failed(message: "Moved pin", offersRecheck: true)
        window.open(skillID: skill.id, context: fixture.context)
        await TestWait.until(failureMessage: "initial pin failure did not settle") { window.state != .loading }
        window.recheck(context: fixture.context)
        let didStart = await TestWait.forSemaphore(started)
        XCTAssertTrue(didStart)
        XCTAssertFalse(sheet.canApply, "The sheet cannot apply a skill while its window Re-check is running")
        try assertSheetControlsAreBlocked(sheet)
        await assertSameSkillSheetIntentsAreBlocked(sheet, row: row, applied: applied, checked: checked)
        XCTAssertTrue(skill.updateAvailable, "A blocked apply must leave the stored update untouched")
        sheet.selectedSkillIDs = [other.id]
        XCTAssertTrue(sheet.canApply, "Window work for one skill must not block another skill's apply")
        XCTAssertTrue(try XCTUnwrap(UpdatesSheetPresentation(sheet).rows.last).recheckEnabled)
        await sheet.recheckAndReport(otherRow, context: fixture.context)
        await sheet.applySelectedAndReport(context: fixture.context)
        XCTAssertEqual(checked.values, [other.id])
        XCTAssertEqual(applied.values, [other.id])
        release.open()
        await TestWait.until(failureMessage: "window check did not finish") { !window.isRechecking }
        sheet.selectedSkillIDs = [skill.id]
        XCTAssertTrue(sheet.canApply, "Sheet apply must become available when the window finishes")
        XCTAssertTrue(try XCTUnwrap(UpdatesSheetPresentation(sheet).rows.first).recheckEnabled)
        await sheet.applySelectedAndReport(context: fixture.context)
        XCTAssertEqual(applied.values, [other.id, skill.id])
        XCTAssertFalse(skill.updateAvailable, "An apply admitted after Re-check must keep its cleared update state")
    }

    private func assertSheetControlsAreBlocked(_ sheet: UpdatesViewModel) throws {
        let presentation = UpdatesSheetPresentation(sheet)
        XCTAssertFalse(presentation.updateEnabled)
        XCTAssertFalse(try XCTUnwrap(presentation.rows.first).recheckEnabled,
                       "The sheet's same-skill Re-check control must be unavailable")
    }

    private func assertSameSkillSheetIntentsAreBlocked(
        _ sheet: UpdatesViewModel, row: UpdatesRow,
        applied: UpdateReviewRecorder<UUID>, checked: UpdateReviewRecorder<UUID>
    ) async {
        sheet.applySelected(context: fixture.context)
        if let task = sheet.operationTask { await TestWait.forTask(task, failureMessage: "unexpected apply did not settle") }
        await sheet.applySelectedAndReport(context: fixture.context)
        sheet.recheck(row, context: fixture.context)
        if let task = sheet.operationTask { await TestWait.forTask(task, failureMessage: "unexpected check did not settle") }
        await sheet.recheckAndReport(row, context: fixture.context)
        XCTAssertEqual(applied.values, [], "No sheet apply may race the window's stale completion")
        XCTAssertEqual(checked.values, [], "No sheet check may race the window's stale completion")
    }

    private func reverseSheet(
        rows: [UpdatesRow], completion: SkillUpdateCompletion,
        applied: UpdateReviewRecorder<UUID>, checked: UpdateReviewRecorder<UUID>
    ) -> UpdatesViewModel {
        UpdatesViewModel(rowLoader: { _ in rows }, applyOperation: { id, _, _, _, _, _ in
            applied.append(id)
            return SkillUpdateCompletion(skillID: id, name: completion.name, skillDescription: completion.skillDescription,
                installedOriginData: completion.installedOriginData, updatedAt: completion.updatedAt)
        }, recheckOperation: { id, _ in
            checked.append(id)
            let row = rows.first { $0.id == id }
            return SkillUpdateRecheckCompletion(row: row, skillID: id, updateAvailable: true,
                lastCheckedAt: Date(), lastCheckedHead: row?.upstreamCommit, upstreamTree: row?.upstreamTree,
                upstreamCommit: row?.upstreamCommit, upstreamCommitDate: row?.updateDate, checkError: nil)
        })
    }
}
