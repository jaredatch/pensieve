import SwiftData
import XCTest
@testable import Pensieve

extension ViewChangesViewModelTests {
    func testDeletionDuringApplyNeverReadsARetiredModel() async throws {
        let skill = try fixture.skill("deleted-during-apply")
        let id = skill.id
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let started = DispatchSemaphore(value: 0)
        let release = TestWait.Gate(owner: self)
        let model = ViewChangesViewModel(operations: fixture.operations(rows: [row], apply: { _, _, _, _, _, _ in
            started.signal()
            try release.wait()
            throw SkillUpdateFlowError.repositoryChanged
        }))
        model.open(skillID: id, context: fixture.context)
        await c4Settled(model)
        model.requestUpdate(library: fixture.library, context: fixture.context, onSuccess: {})
        let didStart = await TestWait.forSemaphore(started)
        XCTAssertTrue(didStart)
        fixture.context.delete(skill)
        try fixture.context.save()
        XCTAssertNil(skill.modelContext, "The fixture must contain an actually deleted SwiftData model")
        let probe = DeletedSkillReadProbe(wrapping: skill.persistentBackingData)
        skill.persistentBackingData = probe
        release.open()
        await TestWait.until(failureMessage: "deleted skill's apply did not settle") { !model.isApplying }
        XCTAssertTrue(probe.propertyReads.isEmpty, "Apply settlement must never read properties from a deleted model")
        XCTAssertEqual(model.state, .stale("This skill was deleted."))
        XCTAssertFalse(model.canUpdate)
    }

    func testLaggingQueryOnSwitchNeedsFetchConfirmationBeforeDeletion() async throws {
        let first = try fixture.skill("query-first")
        let second = try fixture.skill("query-second")
        let id = second.id
        let rows = try [first, second].map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: false) }
        let model = ViewChangesViewModel(operations: fixture.operations(rows: rows))
        model.open(skillID: first.id, context: fixture.context)
        await c4Settled(model)
        model.open(skillID: id, context: fixture.context)
        model.validate(skills: [first], folderRevisions: [:], context: fixture.context)
        await c4Settled(model)
        XCTAssertTrue(model.canUpdate, "A lagging query is not proof that the new skill was deleted")
        XCTAssertEqual(model.row?.id, id)
        fixture.context.delete(second)
        try fixture.context.save()
        model.validate(skills: [first], folderRevisions: [:], context: fixture.context)
        XCTAssertEqual(model.state, .stale("This skill was deleted."))
        XCTAssertFalse(model.canUpdate)
    }

    func testRecheckErrorSurvivesItsOwnIdentityChangeAndStillAllowsRecheck() async throws {
        let skill = try fixture.skill("recheck-error")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let model = ViewChangesViewModel(operations: fixture.operations(rows: [row], diff: { _, _, _, _ in
            throw SkillUpdateFlowError.repositoryChanged
        }, recheck: { id, _ in
            SkillUpdateRecheckCompletion(row: nil, skillID: id, updateAvailable: false,
                lastCheckedAt: Date(), lastCheckedHead: nil, upstreamTree: nil, upstreamCommit: nil,
                upstreamCommitDate: nil, checkError: "Authentication failed during Re-check")
        }))
        model.open(skillID: skill.id, context: fixture.context)
        await c4Settled(model)
        model.recheck(context: fixture.context, library: fixture.library)
        await c4Settled(model)
        model.validate(skills: [skill], folderRevisions: [:], context: fixture.context)
        XCTAssertEqual(model.state, .failed("Authentication failed during Re-check"))
        XCTAssertTrue(model.canRecheck)
        XCTAssertFalse(model.canUpdate)
        // A later, independent deletion still retires this failed presentation.
        fixture.context.delete(skill)
        try fixture.context.save()
        model.validate(skills: [], folderRevisions: [:], context: fixture.context)
        XCTAssertEqual(model.state, .stale("This skill was deleted."))
    }

    func testRecheckCapturesTheCurrentFolderRevisionAfterItsWorkerFinishes() async throws {
        let skill = try fixture.skill("recheck-revision")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let started = DispatchSemaphore(value: 0)
        let release = TestWait.Gate(owner: self)
        let diffs = UpdateReviewRecorder<UUID>()
        let model = ViewChangesViewModel(operations: fixture.operations(rows: [row], diff: { id, _, _, _ in
            diffs.append(id)
            if diffs.values.count == 1 { throw SkillUpdateFlowError.repositoryChanged }
            return UpdateReviewFixture.preview()
        }, recheck: { id, _ in
            started.signal()
            try release.wait()
            return SkillUpdateRecheckCompletion(row: row, skillID: id, updateAvailable: true,
                lastCheckedAt: Date(), lastCheckedHead: row.upstreamCommit, upstreamTree: row.upstreamTree,
                upstreamCommit: row.upstreamCommit, upstreamCommitDate: row.updateDate, checkError: nil)
        }))
        fixture.library.folderChangeRevisions[skill.directoryName] = 3
        model.open(skillID: skill.id, context: fixture.context, folderRevisions: fixture.library.folderChangeRevisions)
        await c4Settled(model)
        model.recheck(context: fixture.context, library: fixture.library)
        let didStart = await TestWait.forSemaphore(started)
        XCTAssertTrue(didStart)
        fixture.library.folderChangeRevisions[skill.directoryName] = 8
        release.open()
        await c4Settled(model)
        model.validate(skills: [skill], folderRevisions: fixture.library.folderChangeRevisions, context: fixture.context)
        XCTAssertTrue(model.canUpdate, "Re-check must reopen with the revision at completion, not its retired identity")
        XCTAssertEqual(diffs.values.count, 2)
    }

    func testWindowApplyRetiresTheSheetsOldPinsAndSelection() async throws {
        let skill = try fixture.skill("external-success")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        // The window re-checked a newer upstream while the sheet retained its original pins.
        skill.upstreamCommit = String(repeating: "3", count: 40)
        skill.upstreamTree = "rechecked-tree"
        let refreshed = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        var origin = try XCTUnwrap(skill.installedOrigin)
        origin.installedCommit = refreshed.upstreamCommit
        origin.installedTree = refreshed.upstreamTree
        let completion = SkillUpdateCompletion(skillID: skill.id, name: skill.name,
            skillDescription: skill.skillDescription, installedOriginData: try JSONEncoder().encode(origin), updatedAt: Date())
        let calls = UpdateReviewRecorder<UUID>()
        let apply: UpdatesViewModel.ApplyOperation = { id, _, _, _, _, _ in
            calls.append(id)
            return completion
        }
        let sheet = fixture.sheet(rows: [row], apply: apply)
        let window = ViewChangesViewModel(operations: fixture.operations(rows: [refreshed], apply: apply),
                                         applyCoordinator: sheet.applyCoordinator)
        sheet.rows = [row]
        sheet.selectedSkillIDs = [row.id]
        window.open(skillID: skill.id, context: fixture.context)
        await c4Settled(window)
        window.requestUpdate(library: fixture.library, context: fixture.context, onSuccess: {})
        await TestWait.until(failureMessage: "window apply did not settle") { !window.isApplying }
        XCTAssertEqual(sheet.status(for: row), .updated, "The open sheet must show the window's real outcome")
        XCTAssertFalse(sheet.isSelected(row), "Completed pins must be retired from the sheet selection")
        sheet.selectAll()
        await sheet.applySelectedAndReport(context: fixture.context)
        XCTAssertEqual(calls.values, [skill.id], "The sheet cannot reapply the pins the window already consumed")
    }

    func testSheetBatchShowsAnotherSurfacesReservationAndItsFailure() async throws {
        for finishesBeforeBatch in [false, true] {
            try await exerciseExternalBatchOutcome(finishesBeforeBatch: finishesBeforeBatch)
        }
    }

    private func exerciseExternalBatchOutcome(finishesBeforeBatch: Bool) async throws {
        let first = try fixture.skill("batch-first-\(finishesBeforeBatch)")
        let external = try fixture.skill("batch-external-\(finishesBeforeBatch)")
        let rows = try [first, external].map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: false) }
        let completion = SkillUpdateCompletion(skillID: first.id, name: first.name,
            skillDescription: first.skillDescription, installedOriginData: first.installedOriginData!, updatedAt: Date())
        let externalCompletion = SkillUpdateCompletion(skillID: external.id, name: external.name,
            skillDescription: external.skillDescription, installedOriginData: external.installedOriginData!, updatedAt: Date())
        let firstStarted = DispatchSemaphore(value: 0)
        let externalStarted = DispatchSemaphore(value: 0)
        let firstRelease = TestWait.Gate(owner: self)
        let externalRelease = TestWait.Gate(owner: self)
        let calls = UpdateReviewRecorder<UUID>()
        let (sheet, window) = fixture.review(rows: rows, apply: { id, _, _, _, _, _ in
            calls.append(id)
            if id == rows[0].id {
                firstStarted.signal()
                try firstRelease.wait()
                return completion
            }
            externalStarted.signal()
            try externalRelease.wait()
            if finishesBeforeBatch { return externalCompletion }
            throw SkillUpdateFlowError.repositoryChanged
        })
        sheet.rows = rows
        sheet.selectedSkillIDs = Set(rows.map(\.id))
        window.open(skillID: external.id, context: fixture.context)
        await c4Settled(window)
        sheet.applySelected(context: fixture.context)
        let didStartFirst = await TestWait.forSemaphore(firstStarted)
        XCTAssertTrue(didStartFirst)
        window.requestUpdate(library: fixture.library, context: fixture.context, onSuccess: {})
        let didStartExternal = await TestWait.forSemaphore(externalStarted)
        XCTAssertTrue(didStartExternal)
        await settleExternalBatchOutcome(finishesBeforeBatch: finishesBeforeBatch, sheet: sheet, window: window,
                                         externalRow: rows[1], firstRelease: firstRelease, externalRelease: externalRelease)
        XCTAssertFalse(sheet.isUpdatingElsewhere(rows[1]))
        XCTAssertEqual(calls.values, rows.map(\.id))
    }

    private func settleExternalBatchOutcome(finishesBeforeBatch: Bool, sheet: UpdatesViewModel, window: ViewChangesViewModel,
                                            externalRow: UpdatesRow, firstRelease: TestWait.Gate,
                                            externalRelease: TestWait.Gate) async {
        if finishesBeforeBatch {
            externalRelease.open()
            await TestWait.until(failureMessage: "external success did not settle") { !window.isApplying }
            XCTAssertEqual(sheet.status(for: externalRow), .updated)
            XCTAssertFalse(sheet.isSelected(externalRow))
            firstRelease.open()
            await TestWait.until(failureMessage: "sheet's captured batch did not settle") { !sheet.isApplyingBatch }
        } else {
            firstRelease.open()
            await TestWait.until(failureMessage: "sheet batch did not settle") { !sheet.isApplyingBatch }
            XCTAssertEqual(sheet.status(for: externalRow), .updating)
            XCTAssertTrue(sheet.isUpdatingElsewhere(externalRow))
            XCTAssertFalse(sheet.canApply)
            externalRelease.open()
            await TestWait.until(failureMessage: "external apply did not settle") { !window.isApplying }
            XCTAssertEqual(sheet.status(for: externalRow),
                           .failed(message: SkillUpdateFlowError.repositoryChangedMessage, offersRecheck: true),
                           "A skipped busy row must receive its real outcome instead of returning silently to idle")
        }
    }

    private func c4Settled(_ model: ViewChangesViewModel) async {
        await TestWait.until(failureMessage: "c4 preview did not settle") { model.state != .loading }
    }
}
