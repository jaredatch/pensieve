import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

extension UpdatesSheetTests {
    func testUpdatedTakesViewChangesPlaceInTheRow() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let skill = try fixture.skill("short"), failed = try fixture.skill("failed"), waiting = try fixture.skill("waiting")
        let rows = try [skill, failed, waiting].map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: false) }
        let success = try completion(for: skill)
        let model = fixture.sheet(rows: rows, apply: { id, _, _, _, _, _ in
            if id == skill.id { return success }
            throw SkillUpdateFlowError.repositoryChanged
        })
        model.present(library: fixture.library)
        await model.loadAndReport(context: fixture.context)
        model.setSelection(false, for: rows[2])
        let before = rowHost(model, index: 0, fixture: fixture)
        let changes = try textFrame("View Changes", in: before)
        let height = before.fittingSize.height
        await model.applySelectedAndReport(context: fixture.context)
        let after = rowHost(model, index: 0, fixture: fixture)
        let updated = try assertUpdatedRow(after, name: skill.name)
        XCTAssertEqual(updated.maxX, changes.maxX, accuracy: 1)
        let name = try textFrame(skill.name, in: after, contains: true)
        XCTAssertLessThan(abs(updated.midY - name.midY), name.height / 2, "Updated belongs on the first line")
        XCTAssertEqual(after.fittingSize.height, height, accuracy: 0.5)
        let pending = rowHost(model, index: 2, fixture: fixture)
        XCTAssertTrue(renderedStrings(pending).joined().contains(waiting.name))
        // Read the enabled state of the mounted production control.
        XCTAssertTrue(try renderedButtonEnabled("View Changes", in: pending))
        let failure = rowHost(model, index: 1, fixture: fixture)
        let failureName = try textFrame(failed.name, in: failure, contains: true)
        let coordinates = try textFrame("1111111 → 2222222", in: failure)
        let message = try textFrame(SkillUpdateFlowError.repositoryChanged.localizedDescription, in: failure)
        XCTAssertGreaterThan(message.minY, max(failureName.maxY, coordinates.maxY))
        XCTAssertTrue(renderedStrings(failure).contains("Re-check"))
    }

    func testUpdatedRowDropsItsLocalEditsBox() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let edited = try fixture.skill("edited"), failed = try fixture.skill("failed")
        let waiting = try fixture.skill("waiting"), plain = try fixture.skill("plain")
        edited.name = "Equal name"
        plain.name = edited.name
        let rows = try [edited, failed, waiting, plain].map {
            try UpdatesViewModel.makeRow(skill: $0, driftedLocally: $0.id != plain.id)
        }
        let completions = try [edited.id: completion(for: edited), plain.id: completion(for: plain)]
        let model = fixture.sheet(rows: rows, apply: { id, _, _, _, _, _ in
            guard let completion = completions[id] else { throw SkillUpdateFlowError.repositoryChanged }
            return completion
        })
        model.present(library: fixture.library)
        await model.loadAndReport(context: fixture.context)
        for index in 0..<3 {
            try assertLocalEditsBox(rowHost(model, index: index, fixture: fixture), confirmed: false, enabled: true)
        }
        model.setDriftConfirmation(true, for: rows[0])
        model.setDriftConfirmation(true, for: rows[1])
        model.setSelection(false, for: rows[2])
        await model.applySelectedAndReport(context: fixture.context)
        let updated = rowHost(model, index: 0, fixture: fixture)
        let unedited = rowHost(model, index: 3, fixture: fixture)
        _ = try assertUpdatedRow(updated, name: edited.name)
        _ = try assertUpdatedRow(unedited, name: plain.name)
        assertNoLocalEditsBox(updated, sameHeightAs: unedited)
        let failure = rowHost(model, index: 1, fixture: fixture)
        XCTAssertTrue(renderedStrings(failure).contains(SkillUpdateFlowError.repositoryChanged.localizedDescription))
        try assertLocalEditsBox(failure, confirmed: true, enabled: true)
        try assertLocalEditsBox(rowHost(model, index: 2, fixture: fixture), confirmed: false, enabled: true)
    }

    func testLocalEditsBoxStaysUntilTheUpdateLands() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let known = try fixture.skill("known"), discovered = try fixture.skill("discovered"), plain = try fixture.skill("plain")
        for skill in [known, discovered, plain] { skill.name = "Equal name" }
        let rows = try [known, discovered, plain].map {
            try UpdatesViewModel.makeRow(skill: $0, driftedLocally: $0.id == known.id)
        }
        let completions = try [known.id: completion(for: known), discovered.id: completion(for: discovered),
                               plain.id: completion(for: plain)]
        let applied = UpdateReviewRecorder<UUID>()
        let started = DispatchSemaphore(value: 0), release = TestWait.Gate(owner: self)
        defer { release.open() }
        let model = fixture.sheet(rows: rows, apply: { id, _, _, confirmed, _, _ in
            if id != plain.id && !confirmed { throw SkillUpdateFlowError.localEditsRequireConfirmation }
            if id == known.id { started.signal(); try release.wait() }
            applied.append(id)
            guard let completion = completions[id] else { throw SkillUpdateFlowError.skillNotFound }
            return completion
        })
        model.present(library: fixture.library)
        await model.loadAndReport(context: fixture.context)
        try assertLocalEditsBox(rowHost(model, index: 0, fixture: fixture), confirmed: false, enabled: true)
        let initiallyUnedited = rowHost(model, index: 1, fixture: fixture)
        XCTAssertFalse(renderedStrings(initiallyUnedited).contains("Replace my local edits"))
        XCTAssertEqual(renderedButtons(in: initiallyUnedited).count, 2)
        await model.applySelectedAndReport(context: fixture.context)
        XCTAssertEqual(applied.values, [plain.id], "Neither edited skill may update without confirmation")
        for index in 0..<2 {
            let host = rowHost(model, index: index, fixture: fixture)
            XCTAssertTrue(renderedStrings(host).contains("Confirm the overwrite for this skill, then update again."))
            try assertLocalEditsBox(host, confirmed: false, enabled: true)
            model.setDriftConfirmation(true, for: model.rows[index])
            try assertLocalEditsBox(rowHost(model, index: index, fixture: fixture), confirmed: true, enabled: true)
        }
        model.applySelected(context: fixture.context)
        let batch = try XCTUnwrap(model.operationTask)
        guard await TestWait.forSemaphore(started) else { return XCTFail("The confirmed update did not start") }
        let updating = rowHost(model, index: 0, fixture: fixture)
        XCTAssertTrue(renderedStrings(updating).contains("Updating…"))
        try assertLocalEditsBox(updating, confirmed: true, enabled: false)
        release.open()
        await TestWait.forTask(batch, failureMessage: "The confirmed update batch did not finish")
        XCTAssertEqual(applied.values, [plain.id, known.id, discovered.id], "Confirmation must allow both retries")
        let unedited = rowHost(model, index: 2, fixture: fixture)
        _ = try assertUpdatedRow(unedited, name: plain.name)
        for index in 0..<2 {
            let updated = rowHost(model, index: index, fixture: fixture)
            _ = try assertUpdatedRow(updated, name: "Equal name")
            assertNoLocalEditsBox(updated, sameHeightAs: unedited)
        }
    }

    func testUpdatedStaysWholeBesideAWrappedNameAndLocalEdits() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let skill = try fixture.skill("wrapped")
        skill.name = "A long skill name with enough words to wrap beside its repository"
        var origin = try XCTUnwrap(skill.installedOrigin)
        origin.repo = "https://github.com/example/a-repository-with-a-long-descriptive-name"
        skill.installedOrigin = origin
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: true)
        let success = try completion(for: skill)
        let model = fixture.sheet(rows: [row], apply: { _, _, _, _, _, _ in success })
        model.present(library: fixture.library)
        await model.loadAndReport(context: fixture.context)
        let before = rowHost(model, index: 0, fixture: fixture)
        let changes = try textFrame("View Changes", in: before)
        model.setDriftConfirmation(true, for: row)
        await model.applySelectedAndReport(context: fixture.context)
        let host = rowHost(model, index: 0, fixture: fixture)
        let updated = try assertUpdatedRow(host, name: skill.name)
        let name = try textFrame(skill.name, in: host, contains: true)
        let singleLine = NSHostingView(rootView: Text(skill.name).font(DesignTokens.updatesRowName)).fittingSize.height
        XCTAssertGreaterThan(name.height, singleLine * 1.5, "The fixture must exercise a wrapped name")
        XCTAssertEqual(updated.maxX, changes.maxX, accuracy: 1)
        XCTAssertLessThan(abs(updated.minY - name.minY), singleLine / 2, "Updated stays at the top beside the wrapped name")
        let label = NSHostingView(rootView: Label("Updated", systemImage: "checkmark.circle.fill").font(.caption))
        let renderedLabel = try labelFrame(in: host)
        XCTAssertGreaterThanOrEqual(renderedLabel.width, label.fittingSize.width - 0.5, "Updated must keep its full width")
        XCTAssertFalse(renderedStrings(host).contains("You have local edits to this skill. Updating replaces them."))
        XCTAssertFalse(renderedStrings(host).contains("Replace my local edits"))
    }

    func testCancelReadsCloseOnceASkillHasUpdated() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let failed = try fixture.skill("failed"), success = try fixture.skill("success"), waiting = try fixture.skill("waiting")
        let rows = try [failed, success, waiting].map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: false) }
        let completion = try completion(for: success)
        let model = fixture.sheet(rows: rows, apply: { id, _, _, _, _, _ in
            if id == success.id { return completion }
            throw SkillUpdateFlowError.repositoryChanged
        })
        model.present(selecting: failed.id, library: fixture.library)
        await model.loadAndReport(context: fixture.context)
        let host = sheetRenderHost(model, fixture: fixture)
        defer { host.rootView = AnyView(EmptyView()) }
        try await assertDismissButton("Cancel", enabled: true, model: model, in: host)
        await model.applySelectedAndReport(context: fixture.context)
        try await assertDismissButton("Cancel", enabled: true, model: model, in: host)
        model.setSelection(false, for: rows[0])
        model.setSelection(true, for: rows[1])
        await model.applySelectedAndReport(context: fixture.context)
        try await assertDismissButton("Close", enabled: true, model: model, in: host)
        model.cancel()
        model.isPresented = false
        model.present(library: fixture.library)
        await model.loadAndReport(context: fixture.context)
        try await assertDismissButton("Cancel", enabled: true, model: model, in: host)
    }

    func testCloseAppearsWithTheFirstUpdateAndStays() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let first = try fixture.skill("first"), second = try fixture.skill("second"), remaining = try fixture.skill("remaining")
        let rows = try [first, second, remaining].map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: false) }
        let completions = try [first.id: completion(for: first), second.id: completion(for: second)]
        let held = DispatchSemaphore(value: 0), release = TestWait.Gate(owner: self)
        defer { release.open() }
        let model = fixture.sheet(rows: rows, apply: { id, _, _, _, _, _ in
            if id == second.id { held.signal(); try release.wait() }
            guard let completion = completions[id] else { throw SkillUpdateFlowError.repositoryChanged }
            return completion
        })
        model.present(library: fixture.library)
        await model.loadAndReport(context: fixture.context)
        model.setSelection(false, for: rows[2])
        let host = sheetRenderHost(model, fixture: fixture)
        defer { host.rootView = AnyView(EmptyView()) }
        try await assertDismissButton("Cancel", enabled: true, model: model, in: host)
        model.applySelected(context: fixture.context)
        let batch = try XCTUnwrap(model.operationTask)
        let started = await TestWait.forSemaphore(held)
        XCTAssertTrue(started)
        try await assertDismissButton("Close", enabled: false, model: model, in: host)
        release.open()
        await TestWait.forTask(batch, failureMessage: "The held update batch did not finish")
        try await assertDismissButton("Close", enabled: true, model: model, in: host)
        model.setSelection(true, for: rows[2])
        await model.applySelectedAndReport(context: fixture.context)
        try await assertDismissButton("Close", enabled: true, model: model, in: host)
    }
}
