import SwiftData
import XCTest
@testable import Pensieve

extension ViewChangesViewModelTests {
    func testLaggingQueryOnSwitchNeedsFetchConfirmationBeforeDeletion() async throws {
        let first = try fixture.skill("query-first")
        let second = try fixture.skill("query-second")
        let id = second.id
        let rows = try [first, second].map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: false) }
        let model = ViewChangesViewModel(library: fixture.library, operations: fixture.operations(rows: rows))
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
        let model = ViewChangesViewModel(library: fixture.library,
            operations: fixture.operations(rows: [row], diff: { _, _ in
            throw SkillUpdateFlowError.repositoryChanged
        }, recheck: { id, _ in
            SkillUpdateRecheckCompletion(row: nil, skillID: id, updateAvailable: false,
                lastCheckedAt: Date(), lastCheckedHead: nil, upstreamTree: nil, upstreamCommit: nil,
                upstreamCommitDate: nil, checkError: "Authentication failed during Re-check")
        }))
        model.open(skillID: skill.id, context: fixture.context)
        await c4Settled(model)
        model.recheck(context: fixture.context)
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
        let model = ViewChangesViewModel(library: fixture.library,
            operations: fixture.operations(rows: [row], diff: { request, _ in
            diffs.append(request.id)
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
        model.recheck(context: fixture.context)
        let didStart = await TestWait.forSemaphore(started)
        XCTAssertTrue(didStart)
        fixture.library.folderChangeRevisions[skill.directoryName] = 8
        release.open()
        await c4Settled(model)
        model.validate(skills: [skill], folderRevisions: fixture.library.folderChangeRevisions, context: fixture.context)
        XCTAssertTrue(model.canUpdate, "Re-check must reopen with the revision at completion, not its retired identity")
        XCTAssertEqual(diffs.values.count, 2)
    }

    private func c4Settled(_ model: ViewChangesViewModel) async {
        await TestWait.until(failureMessage: "c4 preview did not settle") { model.state != .loading }
    }
}
