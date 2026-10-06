import SwiftData
import XCTest
@testable import Pensieve

extension ViewChangesViewModelTests {
    func testRetiredSessionNeverStartsItsDetachedPreview() async throws {
        let first = try fixture.skill("retired")
        let second = try fixture.skill("current")
        let rows = try [first, second].map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: false) }
        let calls = UpdateReviewRecorder<UUID>()
        let model = ViewChangesViewModel(library: fixture.library,
            operations: fixture.operations(rows: rows, diff: { request, _ in
            calls.append(request.id)
            return UpdateReviewFixture.preview()
        }))
        model.open(skillID: first.id, context: fixture.context)
        model.open(skillID: second.id, context: fixture.context)
        await settled(model)
        // A main-actor barrier also lets the cancelled session finish its cleanup.
        await Task.yield()
        XCTAssertEqual(calls.values, [second.id], "Retired sessions must not start orphaned workers")
    }

    func testRetryAfterFirstSkillFetchFails() async throws {
        let skill = try fixture.skill("first-fetch")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        var fetches = 0
        let model = ViewChangesViewModel(library: fixture.library,
            operations: fixture.operations(rows: [row]), skillLookup: { _, _ in
            fetches += 1
            if fetches == 1 { throw SkillUpdateFlowError.skillNotFound }
            return skill
        })
        model.open(skillID: skill.id, context: fixture.context, folderRevisions: [skill.directoryName: 7])
        guard case .failed = model.state else { return XCTFail("First fetch must fail") }
        model.retry(context: fixture.context, folderRevisions: [skill.directoryName: 7])
        await settled(model)
        model.validate(skills: [skill], folderRevisions: [skill.directoryName: 7], context: fixture.context)
        XCTAssertTrue(model.canUpdate, "Retry captures the current folder revision after its first fetch failed")
        XCTAssertEqual(fetches, 2)
        XCTAssertNotNil(model.selectedFile, "Retry must remember the requested skill before its first fetch succeeds")
    }

    func testMovedOrMissingPinsOfferRecheckForPreview() async throws {
        let skill = try fixture.skill("recheck")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        for error in [SkillUpdateFlowError.repositoryChanged, .missingPinnedUpdate] {
            let model = ViewChangesViewModel(library: fixture.library,
                operations: fixture.operations(rows: [row], diff: { _, _ in throw error }))
            model.open(skillID: skill.id, context: fixture.context)
            await settled(model)
            XCTAssertTrue(model.canRecheck, "Moved and missing pins need a fresh check")

        }
    }

    func testSidebarHeaderNeedsALoadedPreviewAndUsesSingular() throws {
        for state in [ViewChangesViewModel.State.idle, .loading, .failed("offline"), .stale("changed")] {
            XCTAssertNil(ViewChangesPresentation.sidebarHeader(state), "No count exists without a preview")
        }
        let one = try PinnedSkillDiff.build(comparison: FileTreeComparison(changes: [
            FileTreeChange(path: "one", kind: .modified, content: .binary)
        ], unreadFileCount: 0, bytesRead: 0))
        XCTAssertEqual(ViewChangesPresentation.sidebarHeader(.loaded(one)), "1 Changed File")
        XCTAssertEqual(ViewChangesPresentation.sidebarHeader(.loaded(UpdateReviewFixture.preview())), "2 Changed Files")
    }

    private func settled(_ model: ViewChangesViewModel) async {
        await TestWait.until(failureMessage: "preview did not settle") { model.state != .loading }
    }
}
