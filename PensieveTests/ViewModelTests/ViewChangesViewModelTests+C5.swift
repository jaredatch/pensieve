import SwiftData
import XCTest
@testable import Pensieve

extension ViewChangesViewModelTests {
    func testReopenedSheetDoesNotRestoreFailuresOrBlockSelection() async throws {
        for replaced in [false, true] {
            let skill = try fixture.skill("reopen-failure-\(replaced)")
            let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
            let sheet = fixture.sheet(rows: [row], apply: { _, _, _, _, _, _ in
                if replaced { throw SyncedStateMutationError(underlyingError: NSError(domain: "replacement", code: 1)) }
                throw SkillUpdateFlowError.repositoryChanged
            })
            await sheet.loadAndReport(context: fixture.context)
            await sheet.applySelectedAndReport(context: fixture.context)
            XCTAssertNotEqual(sheet.status(for: row), .idle)
            sheet.reset()
            await sheet.loadAndReport(context: fixture.context)
            XCTAssertEqual(sheet.status(for: row), .idle, "A prior sheet session's failure must not be restored")
            XCTAssertTrue(sheet.isSelected(row))
            XCTAssertTrue(sheet.canApply, "A reopened failed row must be selectable again")
        }
    }

    func testCancelledSheetApplyDoesNotPublishAFailureIntoTheReopenedSheet() async throws {
        let skill = try fixture.skill("cancelled-sheet")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let started = DispatchSemaphore(value: 0)
        let release = TestWait.Gate(owner: self)
        let sheet = fixture.sheet(rows: [row], apply: { _, _, _, _, _, _ in
            started.signal()
            try release.wait()
            throw CancellationError()
        })
        await sheet.loadAndReport(context: fixture.context)
        sheet.applySelected(context: fixture.context)
        let oldApply = try XCTUnwrap(sheet.operationTask)
        let didStart = await TestWait.forSemaphore(started)
        XCTAssertTrue(didStart)
        sheet.reset()
        await sheet.loadAndReport(context: fixture.context)
        XCTAssertEqual(sheet.status(for: row), .updating)
        XCTAssertEqual(sheet.updatingLabel, "Updating…", "A reopened sheet must not attribute its own apply to View Changes")
        release.open()
        await oldApply.value
        XCTAssertEqual(sheet.status(for: row), .idle, "Cancellation must never become a failure in the current sheet")
        XCTAssertTrue(sheet.canApply)
        sheet.reset()
        await sheet.loadAndReport(context: fixture.context)
        XCTAssertEqual(sheet.status(for: row), .idle)
    }

    func testRecheckWorksAfterTheFirstLookupFailsBeforeARowExists() async throws {
        let skill = try fixture.skill("early-recheck")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let calls = UpdateReviewRecorder<UUID>()
        var lookups = 0
        let model = ViewChangesViewModel(library: fixture.library, operations: fixture.operations(rows: [row], recheck: { id, _ in
            calls.append(id)
            return SkillUpdateRecheckCompletion(row: row, skillID: id, updateAvailable: true,
                lastCheckedAt: Date(), lastCheckedHead: row.upstreamCommit, upstreamTree: row.upstreamTree,
                upstreamCommit: row.upstreamCommit, upstreamCommitDate: row.updateDate, checkError: nil)
        }), skillLookup: { id, context in
            lookups += 1
            if lookups == 1 { throw SkillUpdateFlowError.missingPinnedUpdate }
            return try UpdatesViewModel.findSkill(id, context: context)
        })
        model.open(skillID: skill.id, context: fixture.context)
        XCTAssertNil(model.row)
        XCTAssertTrue(model.canRecheck)
        model.recheck(context: fixture.context, library: fixture.library)
        await TestWait.until(failureMessage: "early Re-check did not settle") { model.state != .loading }
        XCTAssertEqual(calls.values, [skill.id], "Re-check must use the requested ID even without a row")
        XCTAssertTrue(model.canUpdate)
    }

    func testRecheckLocalEditsHasAnActionableFailure() async throws {
        let skill = try fixture.skill("recheck-local-edits")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let operations = fixture.operations(rows: [row], recheck: { _, _ in
            throw SkillUpdateFlowError.localEditsRequireConfirmation
        })
        let sheet = UpdatesViewModel(rowLoader: operations.rowLoader, applyOperation: operations.applyOperation,
            diffOperation: operations.diffOperation, recheckOperation: operations.recheckOperation)
        await sheet.loadAndReport(context: fixture.context)
        await sheet.recheckAndReport(row, context: fixture.context)
        guard case let .failed(message, recheck) = sheet.status(for: row) else {
            return XCTFail("Re-check local edits must offer an actionable failure rather than a dead confirmation")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(recheck)
    }

    func testApplySettlementOnlyValidatesItsSkillUsingTheWindowsOwnRevisions() async throws {
        let first = try fixture.skill("preview-owner")
        let other = try fixture.skill("apply-other")
        let rows = try [first, other].map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: false) }
        let sheet = fixture.sheet(rows: rows)
        var denyLookups = false
        let window = ViewChangesViewModel(library: fixture.library, operations: fixture.operations(rows: rows),
            applyCoordinator: sheet.applyCoordinator, skillLookup: { id, context in
                if denyLookups { throw SkillUpdateFlowError.skillNotFound }
                return try UpdatesViewModel.findSkill(id, context: context)
            })
        fixture.library.folderChangeRevisions[first.directoryName] = 7
        window.open(skillID: first.id, context: fixture.context, folderRevisions: fixture.library.folderChangeRevisions)
        await TestWait.until(failureMessage: "owned preview did not load") { window.state != .loading }
        sheet.rows = rows
        sheet.selectedSkillIDs = [other.id]
        denyLookups = true
        await sheet.applySelectedAndReport(context: fixture.context)
        XCTAssertTrue(window.canUpdate, "An unrelated apply must not validate with another surface's empty revisions")
        denyLookups = false
        window.retry(context: fixture.context, folderRevisions: fixture.library.folderChangeRevisions)
        await TestWait.until(failureMessage: "matching preview did not load") { window.state != .loading }
        sheet.selectedSkillIDs = [first.id]
        await sheet.applySelectedAndReport(context: fixture.context)
        XCTAssertTrue(window.canUpdate, "A matching refusal must validate using the window library's current revision")
    }
}

extension UpdatesViewModelTests {
    func testSheetRetiresOnlyInstalledTargetsAndMovedPinsKeepTheApplyRefusal() async throws {
        let fixture = try prepareRealPinnedUpdate()
        let (operations, library) = makeRealReviewOperations(fixture: fixture)
        let row = try UpdatesViewModel.makeRow(skill: fixture.skill, driftedLocally: false)
        let calls = UpdateReviewRecorder<UUID>()
        let apply = operations.applyOperation
        // A loader can return a snapshot taken before another surface finished updating.
        let sheet = UpdatesViewModel(rowLoader: { _ in [row] },
            applyOperation: { id, commit, tree, overwrite, registration, container in
            calls.append(id)
            return try apply(id, commit, tree, overwrite, registration, container)
        }, diffOperation: operations.diffOperation, recheckOperation: operations.recheckOperation)
        await sheet.loadAndReport(context: context)
        fixture.skill.upstreamCommit = String(repeating: "9", count: 40)
        try context.save()
        XCTAssertTrue(sheet.canApply, "A moved upstream pin must reach apply's existing pre-write check")
        await sheet.applySelectedAndReport(context: context)
        XCTAssertEqual(sheet.status(for: row),
                       .failed(message: SkillUpdateFlowError.repositoryChangedMessage, offersRecheck: true))
        XCTAssertEqual(calls.values, [row.id])
        fixture.skill.upstreamCommit = row.upstreamCommit
        sheet.reset()
        await assertOtherMetadataRemainsEligible(sheet: sheet, row: row, skill: fixture.skill)
        try context.save()
        let window = ViewChangesViewModel(library: library, operations: operations, applyCoordinator: sheet.applyCoordinator)
        window.open(skillID: row.id, context: context)
        await windowLoaded(window)
        window.requestUpdate(library: library, context: context, onSuccess: {})
        await TestWait.until(failureMessage: "window update did not settle") { !window.isApplying }
        // No sheet row was open to receive that outcome; canonical installed state must retire the late snapshot.
        await sheet.loadAndReport(context: context)
        XCTAssertEqual(sheet.status(for: row), .updated)
        XCTAssertFalse(sheet.isSelected(row))
        XCTAssertFalse(sheet.canApply)
        await sheet.applySelectedAndReport(context: context)
        XCTAssertEqual(calls.values, [row.id], "The window's installed target must never be applied again by the sheet")
        var origin = try XCTUnwrap(fixture.skill.installedOrigin)
        XCTAssertEqual(origin.installedCommit, row.upstreamCommit)
        XCTAssertEqual(origin.installedTree, row.upstreamTree)
        origin.installedTree = "different-tree"
        fixture.skill.installedOrigin = origin
        XCTAssertEqual(sheet.status(for: row), .idle, "Matching the commit alone must not retire a row")
        XCTAssertTrue(sheet.canApply)
        context.delete(fixture.skill)
        try context.save()
        XCTAssertEqual(sheet.status(for: row), .updated)
        XCTAssertFalse(sheet.canApply)
    }

    private func assertOtherMetadataRemainsEligible(sheet: UpdatesViewModel, row: UpdatesRow, skill: Skill) async {
        let originalOrigin = skill.installedOriginData
        for change in ["check error", "no update", "unparseable origin"] {
            skill.checkError = change == "check error" ? "offline" : nil
            skill.updateAvailable = change != "no update"
            skill.installedOriginData = change == "unparseable origin" ? Data("origin".utf8) : originalOrigin
            await sheet.loadAndReport(context: context)
            XCTAssertEqual(sheet.status(for: row), .idle, "Other metadata must remain with apply's pre-write checks")
            XCTAssertTrue(sheet.canApply)
            sheet.reset()
        }
        skill.checkError = nil
        skill.updateAvailable = true
        skill.installedOriginData = originalOrigin
    }

}
