import XCTest
@testable import Pensieve

extension ViewChangesViewModelTests {
    func testUnconfirmedDriftSelectionDoesNotBlockWindowRecheckDuringOtherApply() async throws {
        let drifted = try fixture.skill("skipped-drift")
        let other = try fixture.skill("active-apply")
        let driftRow = try UpdatesViewModel.makeRow(skill: drifted, driftedLocally: true)
        let otherRow = try UpdatesViewModel.makeRow(skill: other, driftedLocally: false)
        let started = DispatchSemaphore(value: 0)
        let release = TestWait.Gate(owner: self)
        let applied = UpdateReviewRecorder<UUID>()
        let checked = UpdateReviewRecorder<UUID>()
        let completion = try appliedCompletion(skill: other, row: otherRow)
        let sheet = UpdatesViewModel(rowLoader: { _ in [driftRow, otherRow] }, applyOperation: { id, _, _, _, _, _ in
            applied.append(id)
            started.signal()
            try release.wait()
            return completion
        }, recheckOperation: { _, _ in throw SkillUpdateFlowError.repositoryChanged })
        let window = ViewChangesViewModel(library: fixture.library,
            operations: fixture.operations(rows: [driftRow], diff: { _, _ in throw SkillUpdateFlowError.repositoryChanged },
                recheck: { id, _ in
                    checked.append(id)
                    return SkillUpdateRecheckCompletion(row: driftRow, skillID: id, updateAvailable: true,
                        lastCheckedAt: Date(), lastCheckedHead: driftRow.upstreamCommit, upstreamTree: driftRow.upstreamTree,
                        upstreamCommit: driftRow.upstreamCommit, upstreamCommitDate: driftRow.updateDate,
                        checkError: "Check failed")
                }), updates: sheet)
        sheet.present(library: fixture.library)
        await sheet.loadAndReport(context: fixture.context)
        window.open(skillID: drifted.id, context: fixture.context)
        await TestWait.until(failureMessage: "initial pin failure did not settle") { window.state != .loading }
        sheet.applySelected(context: fixture.context)
        let task = try XCTUnwrap(sheet.operationTask)
        let didStart = await TestWait.forSemaphore(started)
        XCTAssertTrue(didStart)
        XCTAssertEqual(sheet.status(for: driftRow), .confirmationRequired)
        XCTAssertTrue(sheet.selectedSkillIDs.contains(drifted.id))
        XCTAssertFalse(sheet.isBusy(affecting: drifted.id), "An unconfirmed drifted row is skipped by apply")
        XCTAssertTrue(sheet.isBusy(affecting: other.id), "The row actually being applied must remain busy")
        XCTAssertTrue(window.canRecheck, "A selected but skipped drifted row must keep window Re-check available")
        window.recheck(context: fixture.context)
        await TestWait.until(failureMessage: "window Re-check did not settle") { !window.isRechecking }
        XCTAssertEqual(checked.values, [drifted.id], "Window Re-check must run while the unrelated apply is held")
        XCTAssertTrue(sheet.isApplying)
        release.open()
        await TestWait.forTask(task, failureMessage: "sheet apply did not settle")
        XCTAssertEqual(applied.values, [other.id], "The unconfirmed row must never reach the apply worker")
        XCTAssertEqual(sheet.status(for: otherRow), .updated)
    }
}
