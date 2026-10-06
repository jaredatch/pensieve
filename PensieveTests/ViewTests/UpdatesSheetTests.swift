import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class UpdatesSheetTests: XCTestCase {
    func testPresentationShowsCopySelectionAndDriftConfirmation() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let plain = try fixture.skill("plain"), drifted = try fixture.skill("drifted")
        let rows = try [UpdatesViewModel.makeRow(skill: plain, driftedLocally: false),
                        UpdatesViewModel.makeRow(skill: drifted, driftedLocally: true)]
        let applies = UpdateReviewRecorder<UUID>()
        let completion = try completion(for: drifted)
        let model = fixture.sheet(rows: rows, apply: { id, _, _, _, _, _ in applies.append(id); return completion })
        model.present(selecting: plain.id, library: fixture.library)
        await model.loadAndReport(context: fixture.context)
        var shown = UpdatesSheetPresentation(model)
        assertFrameCopy(shown)
        assertSelectionBindings(model, rows: rows, library: fixture.library)
        UpdatesSheetPresentation(model).selectionSources.forEach { $0.wrappedValue = true }
        XCTAssertEqual(UpdatesSheetPresentation(model).selectionSources.map(\.wrappedValue), [true, true])
        UpdatesSheetPresentation(model).selectionSources.forEach { $0.wrappedValue = false }
        XCTAssertEqual(UpdatesSheetPresentation(model).selectionSources.map(\.wrappedValue), [false, false])
        model.setSelection(true, for: rows[1])
        await model.applySelectedAndReport(context: fixture.context)
        shown = UpdatesSheetPresentation(model)
        XCTAssertTrue(applies.values.isEmpty)
        XCTAssertEqual(shown.rows[1].statusText, "Confirm the overwrite for this skill, then update again.")
        UpdatesSheetPresentation(model).selectionSources.forEach { $0.wrappedValue = false }
        model.setDriftConfirmation(true, for: rows[1])
        shown = UpdatesSheetPresentation(model)
        XCTAssertTrue(shown.rows[1].isSelected, "Checking Replace also selects the row")
        XCTAssertTrue(shown.rows[1].replacementConfirmed)
        model.setDriftConfirmation(false, for: rows[1])
        XCTAssertTrue(UpdatesSheetPresentation(model).rows[1].isSelected, "Unchecking Replace preserves selection")
        model.setDriftConfirmation(true, for: rows[1])
        await model.applySelectedAndReport(context: fixture.context)
        XCTAssertEqual(applies.values, [drifted.id])
        shown = UpdatesSheetPresentation(model)
        XCTAssertEqual(shown.rows[1].statusText, "Updated")
        XCTAssertFalse(shown.rows[1].changesEnabled, "Updated rows cannot open an obsolete update preview")
        XCTAssertFalse(shown.rows[1].selectionEnabled)
        XCTAssertFalse(shown.rows[1].replacementEnabled)
        XCTAssertEqual(shown.selectionLabel, "0 of 1 selected", "Updated rows leave the selectable count")
        UpdatesSheetPresentation(model).selectionSources.forEach { $0.wrappedValue = true }
        shown = UpdatesSheetPresentation(model)
        XCTAssertEqual(shown.selectionLabel, "1 of 1 selected")
        XCTAssertEqual(shown.selectionSources.map(\.wrappedValue), [true], "Select-all can reach checked after an update")
    }

    func testPresentationDisablesCancelForBatchAndShowsSelectedRowResults() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let first = try fixture.skill("failed"), second = try fixture.skill("updated"), third = try fixture.skill("unchecked")
        let rows = try [first, second, third].map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: false) }
        let calls = UpdateReviewRecorder<UUID>()
        let started = DispatchSemaphore(value: 0), release = TestWait.Gate(owner: self)
        let success = try completion(for: second)
        let model = fixture.sheet(rows: rows, apply: { id, _, _, _, _, _ in
            calls.append(id)
            if id == first.id { started.signal(); try release.wait(); throw SkillUpdateFlowError.repositoryChanged }
            return success
        })
        model.present(library: fixture.library)
        await model.loadAndReport(context: fixture.context)
        model.setSelection(false, for: rows[2])
        XCTAssertTrue(UpdatesSheetPresentation(model).cancelEnabled)
        model.applySelected(context: fixture.context)
        let batch = try XCTUnwrap(model.operationTask)
        let didStart = await TestWait.forSemaphore(started)
        XCTAssertTrue(didStart)
        var shown = UpdatesSheetPresentation(model)
        XCTAssertFalse(shown.cancelEnabled, "Cancel remains disabled while the real worker is blocked")
        XCTAssertFalse(shown.updateEnabled)
        XCTAssertFalse(shown.selectionEnabled)
        XCTAssertTrue(shown.rows.allSatisfy { !$0.selectionEnabled && !$0.changesEnabled })
        XCTAssertEqual(shown.rows[0].statusText, "Updating…")
        release.open()
        await TestWait.forTask(batch, failureMessage: "Presentation batch did not finish")
        shown = UpdatesSheetPresentation(model)
        XCTAssertEqual(calls.values, [first.id, second.id], "A failure continues to the next selected row only")
        XCTAssertEqual(shown.rows[0].statusText, SkillUpdateFlowError.repositoryChanged.localizedDescription)
        XCTAssertTrue(shown.rows[0].showsRecheck)
        XCTAssertTrue(shown.rows[0].recheckEnabled)
        XCTAssertEqual(shown.rows[0].recheckTitle, "Re-check")
        XCTAssertEqual(shown.rows[1].statusText, "Updated")
        XCTAssertFalse(shown.rows[1].changesEnabled, "Updated rows cannot open an obsolete update preview")
        XCTAssertNil(shown.rows[2].statusText)
        XCTAssertTrue(shown.cancelEnabled)
        XCTAssertFalse(shown.rows[1].selectionEnabled)
        UpdatesSheetPresentation(model).selectionSources.forEach { $0.wrappedValue = true }
        XCTAssertEqual(model.selectedSkillIDs, [first.id, third.id])
    }

    func testFailedLoadPresentationHasRetryNoRowsAndNoApply() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let skill = try fixture.skill("retry")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let loads = UpdateReviewRecorder<Bool>(), applies = UpdateReviewRecorder<UUID>()
        let model = UpdatesViewModel(rowLoader: { _ in
            loads.append(true)
            if loads.values.count == 1 { throw SkillUpdateFlowError.repositoryChanged }
            return [row]
        }, applyOperation: { id, _, _, _, _, _ in applies.append(id); throw SkillUpdateFlowError.repositoryChanged },
        recheckOperation: { _, _ in throw SkillUpdateFlowError.skillNotFound })
        model.present(selecting: skill.id, library: fixture.library)
        XCTAssertEqual(UpdatesSheetPresentation(model).content, .loading)
        XCTAssertNil(UpdatesSheetPresentation(model).selectionLabel, "No select-all row while loading")
        await model.loadAndReport(context: fixture.context)
        var shown = UpdatesSheetPresentation(model)
        XCTAssertEqual(shown.content, .failed(SkillUpdateFlowError.repositoryChanged.localizedDescription))
        XCTAssertEqual(shown.errorTitle, "Couldn't Load Updates")
        XCTAssertEqual(shown.retryTitle, "Retry")
        XCTAssertTrue(shown.rows.isEmpty)
        XCTAssertFalse(shown.updateEnabled)
        XCTAssertNil(shown.selectionLabel, "No select-all row on a load error")
        await model.applySelectedAndReport(context: fixture.context)
        XCTAssertTrue(applies.values.isEmpty)
        model.load(context: fixture.context)
        let retry = try XCTUnwrap(model.operationTask)
        XCTAssertEqual(UpdatesSheetPresentation(model).content, .loading)
        await TestWait.forTask(retry, failureMessage: "Retry did not finish")
        shown = UpdatesSheetPresentation(model)
        XCTAssertEqual(shown.content, .rows)
        XCTAssertEqual(shown.rows.map(\.id), [skill.id])
        XCTAssertTrue(shown.updateEnabled)
        model.rows = []
        shown = UpdatesSheetPresentation(model)
        XCTAssertEqual(shown.content, .empty)
        XCTAssertNil(shown.selectionLabel, "No select-all row when empty")
    }
}
