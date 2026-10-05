import SwiftData
import XCTest
@testable import Pensieve

extension ViewChangesViewModelTests {
    func testOneApplyPerSkillSurvivesReopenAndIsVisibleToBothSurfaces() async throws {
        for source in 0..<3 { try await exerciseSharedApply(source: source) }
    }

    private func exerciseSharedApply(source: Int) async throws {
        let skill = try fixture.skill("shared-\(source)")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let calls = UpdateReviewRecorder<UUID>()
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let gate = TestWait.Gate(owner: self)
        let (sheet, window) = fixture.review(rows: [row], apply: { id, _, _, _, _, _ in
            calls.append(id)
            if calls.values.count == 1 {
                started.signal()
                try gate.wait()
                finished.signal()
            }
            throw SkillUpdateFlowError.repositoryChanged
        })
        sheet.rows = [row]
        sheet.selectedSkillIDs = [row.id]
        window.open(skillID: skill.id, context: fixture.context)
        await settled(window)
        startApply(source: source, sheet: sheet, window: window)
        let didStart = await TestWait.forSemaphore(started)
        XCTAssertTrue(didStart)
        XCTAssertEqual(sheet.status(for: row), .updating, "Either surface must show the running apply")
        XCTAssertFalse(sheet.canApply)
        XCTAssertTrue(window.isApplying)
        XCTAssertFalse(window.canUpdate)
        await sheet.applySelectedAndReport(context: fixture.context)
        window.open(skillID: skill.id, context: fixture.context)
        await settled(window)
        XCTAssertTrue(window.isApplying, "Reopening must retain the shared apply")
        let preview = window.state
        sheet.reset()
        XCTAssertEqual(window.state, preview)
        XCTAssertTrue(window.isApplying, "Reset cannot release a worker still writing")
        sheet.present(selecting: skill.id, library: fixture.library)
        await sheet.loadAndReport(context: fixture.context)
        XCTAssertEqual(sheet.status(for: row), .updating)
        XCTAssertFalse(sheet.canApply)
        window.requestUpdate(library: fixture.library, context: fixture.context, onSuccess: {})
        gate.open()
        let didFinish = await TestWait.forSemaphore(finished)
        XCTAssertTrue(didFinish)
        await TestWait.until(failureMessage: "shared apply did not settle") { !window.isApplying }
        XCTAssertEqual(calls.values, [skill.id], "Only one operation may touch the vendored folder")
    }

    private func startApply(source: Int, sheet: UpdatesViewModel, window: ViewChangesViewModel) {
        if source != 0 { sheet.applySelected(context: fixture.context) }
        if source != 1 {
            window.requestUpdate(library: fixture.library, context: fixture.context, onSuccess: {})
        }
    }

    func testRetiredSessionNeverStartsItsDetachedPreview() async throws {
        let first = try fixture.skill("retired")
        let second = try fixture.skill("current")
        let rows = try [first, second].map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: false) }
        let calls = UpdateReviewRecorder<UUID>()
        let model = ViewChangesViewModel(operations: fixture.operations(rows: rows, diff: { id, _, _, _ in
            calls.append(id)
            return UpdateReviewFixture.preview()
        }))
        model.open(skillID: first.id, context: fixture.context)
        model.open(skillID: second.id, context: fixture.context)
        await settled(model)
        // A main-actor barrier also lets the cancelled session finish its cleanup.
        await Task.yield()
        XCTAssertEqual(calls.values, [second.id], "Retired sessions must not start orphaned workers")
    }

    func testApplyFailureAndConfirmationRevalidateChangesMadeWhileApplying() async throws {
        for confirmation in [false, true] {
            let skill = try fixture.skill(confirmation ? "confirmation" : "failure")
            let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
            let started = DispatchSemaphore(value: 0)
            let gate = TestWait.Gate(owner: self)
            let model = ViewChangesViewModel(operations: fixture.operations(rows: [row], apply: { _, _, _, _, _, _ in
                started.signal()
                try gate.wait()
                throw confirmation ? SkillUpdateFlowError.localEditsRequireConfirmation : .repositoryChanged
            }))
            model.open(skillID: skill.id, context: fixture.context)
            await settled(model)
            model.requestUpdate(library: fixture.library, context: fixture.context, onSuccess: {})
            let didStart = await TestWait.forSemaphore(started)
            XCTAssertTrue(didStart)
            skill.updatedAt = skill.updatedAt.addingTimeInterval(1)
            model.validate(skills: [skill], folderRevisions: [skill.directoryName: 1])
            gate.open()
            await TestWait.until(failureMessage: "apply did not settle") { !model.isApplying }
            guard case .stale = model.state else {
                return XCTFail("A change during apply must retire the preview after it settles")
            }
            XCTAssertFalse(model.canUpdate)
        }
    }

    func testRetryAfterFirstSkillFetchFails() async throws {
        let skill = try fixture.skill("first-fetch")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        var fetches = 0
        let model = ViewChangesViewModel(operations: fixture.operations(rows: [row]), skillLookup: { _, _ in
            fetches += 1
            if fetches == 1 { throw SkillUpdateFlowError.skillNotFound }
            return skill
        })
        model.open(skillID: skill.id, context: fixture.context, folderRevisions: [skill.directoryName: 7])
        guard case .failed = model.state else { return XCTFail("First fetch must fail") }
        model.retry(context: fixture.context, folderRevisions: [skill.directoryName: 7])
        await settled(model)
        model.validate(skills: [skill], folderRevisions: [skill.directoryName: 7])
        XCTAssertTrue(model.canUpdate, "Retry captures the current folder revision after its first fetch failed")
        XCTAssertEqual(fetches, 2)
        XCTAssertNotNil(model.selectedFile, "Retry must remember the requested skill before its first fetch succeeds")
    }

    func testUpdateUsesTheSkillAlreadyLoadedByOpen() async throws {
        let skill = try fixture.skill("lookup-once")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        var fetches = 0
        let model = ViewChangesViewModel(operations: fixture.operations(rows: [row]), skillLookup: { _, _ in
            fetches += 1
            return skill
        })
        model.open(skillID: skill.id, context: fixture.context)
        await settled(model)
        model.requestUpdate(library: fixture.library, context: fixture.context, onSuccess: {})
        await TestWait.until(failureMessage: "apply did not settle") { !model.isApplying }
        XCTAssertEqual(fetches, 1, "Opening and Update share one skill lookup")
    }

    func testMovedOrMissingPinsOfferRecheckForPreviewAndApply() async throws {
        let skill = try fixture.skill("recheck")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        for error in [SkillUpdateFlowError.repositoryChanged, .missingPinnedUpdate] {
            let model = ViewChangesViewModel(operations: fixture.operations(rows: [row], diff: { _, _, _, _ in throw error }))
            model.open(skillID: skill.id, context: fixture.context)
            await settled(model)
            XCTAssertTrue(model.canRecheck, "Moved and missing pins need a fresh check")
            let applying = ViewChangesViewModel(operations: fixture.operations(rows: [row],
                apply: { _, _, _, _, _, _ in throw error }))
            applying.open(skillID: skill.id, context: fixture.context)
            await settled(applying)
            applying.requestUpdate(library: fixture.library, context: fixture.context, onSuccess: {})
            await TestWait.until(failureMessage: "apply refusal did not settle") { !applying.isApplying }
            XCTAssertTrue(applying.canRecheck, "Apply refusals need the same Re-check action")
        }
    }

    func testSidebarHeaderNeedsALoadedPreviewAndUsesSingular() {
        for state in [ViewChangesViewModel.State.idle, .loading, .failed("offline"), .stale("changed")] {
            XCTAssertNil(ViewChangesPresentation.sidebarHeader(state), "No count exists without a preview")
        }
        let one = PinnedSkillDiff(comparison: FileTreeComparison(changes: [
            FileTreeChange(path: "one", kind: .modified, content: .binary)
        ], unreadFileCount: 0, bytesRead: 0))
        XCTAssertEqual(ViewChangesPresentation.sidebarHeader(.loaded(one)), "1 Changed File")
        XCTAssertEqual(ViewChangesPresentation.sidebarHeader(.loaded(UpdateReviewFixture.preview())), "2 Changed Files")
    }

    private func settled(_ model: ViewChangesViewModel) async {
        await TestWait.until(failureMessage: "preview did not settle") { model.state != .loading }
    }
}
