import SwiftData
import XCTest
@testable import Pensieve

extension ViewChangesViewModelTests {
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
        model.recheck(context: fixture.context)
        await TestWait.until(failureMessage: "early Re-check did not settle") { model.state != .loading }
        XCTAssertEqual(calls.values, [skill.id], "Re-check must use the requested ID even without a row")
        XCTAssertTrue(model.canUpdate)
    }

}
