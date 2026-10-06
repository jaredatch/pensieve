import SwiftData
import XCTest
@testable import Pensieve

extension UpdatesViewModelTests {
    func testUpdatedRowCannotBeReselectedByRowSelectAllReplacementOrHandoff() async throws {
        let first = insertUpdateSkill(slug: "updated-first")
        let second = insertUpdateSkill(slug: "remaining-second")
        try context.save()
        let rows = try [first, second].map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: true) }
        let calls = LockedCallRecorder()
        let model = makeModel(rows: rows, apply: { id, _, _, _, _, _ in
            calls.append(id)
            return try self.completion(for: first)
        })
        model.present(selecting: first.id, library: library)
        await model.loadAndReport(context: context)
        model.setDriftConfirmation(true, for: rows[0])
        await model.applySelectedAndReport(context: context)
        XCTAssertEqual(calls.values, [first.id])
        XCTAssertEqual(model.status(for: rows[0]), .updated)
        model.setSelection(true, for: rows[0])
        XCTAssertFalse(model.isSelected(rows[0]), "The row checkbox cannot reselect an updated row")
        UpdatesSheetPresentation(model).selectionSources.forEach { $0.wrappedValue = true }
        XCTAssertEqual(model.selectedSkillIDs, [second.id], "Select-all excludes rows updated in this session")
        UpdatesSheetPresentation(model).selectionSources.forEach { $0.wrappedValue = false }
        model.present(selecting: first.id, library: library)
        XCTAssertTrue(model.selectedSkillIDs.isEmpty, "A window hand-off cannot reselect an updated row")
        model.setDriftConfirmation(true, for: rows[0])
        XCTAssertEqual(model.status(for: rows[0]), .updated, "Replacement confirmation cannot revive an updated row")
        // Even a stale selection from a caller cannot make the batch repeat a completed row.
        model.selectedSkillIDs = [first.id]
        await model.applySelectedAndReport(context: context)
        XCTAssertEqual(calls.values, [first.id], "The batch must not apply this session's updated row twice")
    }

    func testFailedLoadHasNoRowsOrApplyAndRetryUsesPresentationSelection() async throws {
        let first = insertUpdateSkill(slug: "retry-first")
        let second = insertUpdateSkill(slug: "retry-second")
        try context.save()
        let rows = try [first, second].map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: false) }
        let loads = LockedBoolRecorder()
        let applies = LockedCallRecorder()
        let model = UpdatesViewModel(rowLoader: { _ in
            loads.append(true)
            if loads.values.count == 1 { throw FixtureError.expectedFailure }
            return rows
        }, applyOperation: { id, _, _, _, _, _ in
            applies.append(id)
            throw FixtureError.expectedFailure
        }, recheckOperation: { _, _ in throw FixtureError.expectedFailure })
        model.present(selecting: first.id, library: library)
        await model.loadAndReport(context: context)
        XCTAssertEqual(model.loadPhase, .failed("fixture update failed"))
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.canApply)
        await model.applySelectedAndReport(context: context)
        XCTAssertTrue(applies.values.isEmpty)
        await model.loadAndReport(context: context)
        XCTAssertEqual(loads.values.count, 2)
        XCTAssertEqual(model.loadPhase, .loaded)
        XCTAssertEqual(model.selectedSkillIDs, [first.id])
        model.setSelection(true, for: rows[1])
        await model.loadAndReport(context: context)
        XCTAssertEqual(loads.values.count, 2, "A loaded presentation never loads again")
        XCTAssertEqual(model.selectedSkillIDs, [first.id, second.id], "Repeated appearance cannot reset choices")
        model.reset()
        model.present(selecting: second.id, library: library)
        await model.loadAndReport(context: context)
        XCTAssertEqual(loads.values.count, 3, "A new presentation loads once")
        XCTAssertEqual(model.selectedSkillIDs, [second.id])
    }
}
