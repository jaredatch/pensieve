import AppKit
import XCTest
@testable import Pensieve

extension UpdateReviewRoutingTests {
    func testWindowUpdateHandsOffToClosedOpenAndApplyingSheetWithoutApplying() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let first = try fixture.skill("handoff-first")
        let second = try fixture.skill("handoff-second")
        let missing = try fixture.skill("not-in-sheet")
        let rows = try [first, second, missing].map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: false) }
        let calls = UpdateReviewRecorder<UUID>()
        let started = DispatchSemaphore(value: 0)
        let release = TestWait.Gate(owner: self)
        let sheet = fixture.sheet(rows: Array(rows.prefix(2)), apply: { id, _, _, _, _, _ in
            calls.append(id)
            started.signal()
            try release.wait()
            throw SkillUpdateFlowError.repositoryChanged
        })
        let preview = ViewChangesViewModel(library: fixture.library, operations: fixture.operations(rows: rows))
        var opened: [String] = []
        let routing = UpdateReviewRouting(preview: preview, updates: sheet, library: fixture.library,
                                         context: fixture.context, windows: { [] }, openWindow: { opened.append($0) })
        routing.presentChanges(skillID: second.id)
        await handoffLoaded(preview)
        routing.window.onUpdate()
        XCTAssertTrue(sheet.isPresented, "Window Update must open the sheet, not apply")
        await sheet.loadAndReport(context: fixture.context)
        XCTAssertEqual(sheet.selectedSkillIDs, [second.id], "A closed sheet selects only the requested skill")
        XCTAssertEqual(opened.last, "main", "The hand-off must bring the main window forward")
        XCTAssertTrue(calls.values.isEmpty, "The window press must never run apply")
        XCTAssertNotNil(preview.selectedFile, "The window stays open after handing off")

        await assertPendingHandoffs(fixture, routing, first: first, second: second.id, calls: calls)

        sheet.reset()
        routing.banner(for: first).onUpdate()
        sheet.load(context: fixture.context)
        XCTAssertTrue(sheet.isLoading)
        routing.window.onUpdate()
        await TestWait.until(failureMessage: "loading hand-off did not finish") { !sheet.isLoading }
        XCTAssertEqual(sheet.selectedSkillIDs, [first.id, second.id],
                       "A hand-off during loading must join the pending initial selection")
        XCTAssertTrue(calls.values.isEmpty, "Loading hand-offs never apply")

        sheet.selectedSkillIDs = [first.id]
        routing.window.onUpdate()
        XCTAssertEqual(sheet.selectedSkillIDs, [first.id, second.id], "An open sheet adds to its selection")
        XCTAssertTrue(calls.values.isEmpty)
        routing.presentChanges(skillID: missing.id)
        await handoffLoaded(preview)
        let forwards = opened.filter { $0 == "main" }.count
        routing.window.onUpdate()
        XCTAssertEqual(opened.filter { $0 == "main" }.count, forwards + 1, "A missing row still brings the sheet forward")
        XCTAssertEqual(sheet.selectedSkillIDs, [first.id, second.id])

        await assertApplyingHandoff(routing: routing, first: first.id, second: second.id,
                                   calls: calls, sync: (started, release), forwards: { opened.filter { $0 == "main" }.count })
    }

    private func assertPendingHandoffs(
        _ fixture: UpdateReviewFixture, _ routing: UpdateReviewRouting,
        first: Skill, second: UUID, calls: UpdateReviewRecorder<UUID>
    ) async {
        let sheet = routing.updates
        sheet.reset()
        routing.banner(for: first).onUpdate()
        XCTAssertTrue(sheet.isPresented)
        XCTAssertFalse(sheet.isLoading)
        XCTAssertTrue(sheet.rows.isEmpty)
        routing.window.onUpdate()
        await sheet.loadAndReport(context: routing.context)
        XCTAssertEqual(sheet.selectedSkillIDs, [first.id, second],
                       "A hand-off before loading starts must join the pending initial selection")
        XCTAssertTrue(calls.values.isEmpty, "Pre-load hand-offs never apply")
        await assertLoadErrorHandoff(fixture: fixture, rows: sheet.rows, preview: routing.preview,
                                    initialSkillID: first.id, windowSkillID: second)
        await assertLoadedHandoffSurvivesReload(routing, first: first, second: second, calls: calls)
    }

    private func assertLoadErrorHandoff(
        fixture: UpdateReviewFixture, rows: [UpdatesRow], preview: ViewChangesViewModel,
        initialSkillID: UUID, windowSkillID: UUID
    ) async {
        let loads = UpdateReviewRecorder<Bool>()
        let applies = UpdateReviewRecorder<UUID>()
        let sheet = UpdatesViewModel(rowLoader: { _ in
            loads.append(true)
            if loads.values.count == 1 { throw SkillUpdateFlowError.repositoryChanged }
            return rows
        }, applyOperation: { id, _, _, _, _, _ in
            applies.append(id)
            throw SkillUpdateFlowError.repositoryChanged
        }, recheckOperation: { _, _ in throw SkillUpdateFlowError.skillNotFound })
        var forwards = 0
        let routing = UpdateReviewRouting(preview: preview, updates: sheet, library: fixture.library,
                                         context: fixture.context, windows: { [] }, openWindow: { _ in forwards += 1 })
        XCTAssertNotEqual(initialSkillID, windowSkillID, "The hand-off must add a different skill")
        XCTAssertEqual(preview.requestedSkillID, windowSkillID)
        routing.presentUpdates(skillID: initialSkillID)
        await sheet.loadAndReport(context: fixture.context)
        XCTAssertNotNil(sheet.loadError, "The first real sheet load must fail")
        XCTAssertFalse(sheet.isLoading)
        let before = forwards
        routing.window.onUpdate()
        XCTAssertEqual(forwards, before + 1, "A failed sheet is still brought forward")
        sheet.load(context: fixture.context) // The production Retry action.
        await TestWait.until(failureMessage: "hand-off Retry did not load rows") { !sheet.isLoading }
        XCTAssertNil(sheet.loadError)
        XCTAssertEqual(sheet.selectedSkillIDs, [initialSkillID, windowSkillID],
                       "A hand-off after a load error must remain selected when Retry loads rows")
        XCTAssertTrue(applies.values.isEmpty, "A load-error hand-off and Retry never apply")
    }

    private func assertLoadedHandoffSurvivesReload(
        _ routing: UpdateReviewRouting, first: Skill, second: UUID, calls: UpdateReviewRecorder<UUID>
    ) async {
        let sheet = routing.updates
        sheet.reset()
        routing.banner(for: first).onUpdate()
        await sheet.loadAndReport(context: routing.context)
        XCTAssertEqual(sheet.selectedSkillIDs, [first.id])
        routing.window.onUpdate()
        XCTAssertEqual(sheet.selectedSkillIDs, [first.id, second])
        await sheet.loadAndReport(context: routing.context)
        XCTAssertEqual(sheet.selectedSkillIDs, [first.id, second],
                       "An accepted loaded hand-off must survive a reload of the same sheet session")
        XCTAssertTrue(calls.values.isEmpty, "A hand-off and reload never apply")
        guard let secondRow = sheet.rows.first(where: { $0.id == second }) else {
            XCTFail("The handed-off skill must have a row")
            return
        }
        sheet.toggleSelection(secondRow)
        await sheet.loadAndReport(context: routing.context)
        XCTAssertEqual(sheet.selectedSkillIDs, [first.id],
                       "A handed-off row later unchecked must stay unchecked after reload")

        sheet.reset()
        routing.banner(for: first).onUpdate()
        await sheet.loadAndReport(context: routing.context)
        sheet.toggleSelection(secondRow)
        await sheet.loadAndReport(context: routing.context)
        XCTAssertEqual(sheet.selectedSkillIDs, [first.id, second],
                       "A manually checked row must stay checked after reload")
        XCTAssertTrue(calls.values.isEmpty, "Selection changes and reloads never apply")
    }

    private func assertApplyingHandoff(routing: UpdateReviewRouting, first: UUID, second: UUID,
                                       calls: UpdateReviewRecorder<UUID>, sync: (DispatchSemaphore, TestWait.Gate),
                                       forwards: () -> Int) async {
        let sheet = routing.updates, preview = routing.preview
        sheet.selectedSkillIDs = [first]
        sheet.applySelected(context: routing.context)
        let didStart = await TestWait.forSemaphore(sync.0)
        XCTAssertTrue(didStart)
        let operation = sheet.operationID
        routing.presentChanges(skillID: second)
        await handoffLoaded(preview)
        let applyingForwards = forwards()
        routing.window.onUpdate()
        XCTAssertEqual(forwards(), applyingForwards + 1)
        XCTAssertEqual(sheet.selectedSkillIDs, [first], "A hand-off cannot change an applying sheet's selection")
        XCTAssertEqual(sheet.operationID, operation, "A hand-off cannot reset or cancel the sheet's batch")
        XCTAssertTrue(sheet.isApplying)
        XCTAssertEqual(calls.values, [first], "Only the sheet's explicit Update starts an apply")
        sync.1.open()
        await TestWait.until(failureMessage: "hand-off sheet apply did not settle") { !sheet.isApplying }
        XCTAssertNotNil(preview.selectedFile)
    }

    func testWindowHandoffSelectsDriftedSkillAndSheetWaitsForReplaceConfirmation() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let skill = try fixture.skill("handoff-drift")
        let other = try fixture.skill("handoff-other")
        let rows = try [skill, other].map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: true) }
        let calls = UpdateReviewRecorder<Bool>()
        let (sheet, preview) = fixture.review(rows: rows, apply: { _, _, _, overwrite, _, _ in
            calls.append(overwrite)
            throw SkillUpdateFlowError.repositoryChanged
        })
        let routing = UpdateReviewRouting(preview: preview, updates: sheet, library: fixture.library,
                                         context: fixture.context, windows: { [] }, openWindow: { _ in })
        routing.presentChanges(skillID: skill.id)
        await handoffLoaded(preview)
        routing.window.onUpdate()
        await sheet.loadAndReport(context: fixture.context)
        XCTAssertEqual(sheet.selectedSkillIDs, [skill.id])
        XCTAssertTrue(calls.values.isEmpty, "A drifted hand-off never applies")
        await sheet.applySelectedAndReport(context: fixture.context)
        XCTAssertEqual(sheet.status(for: rows[0]), .confirmationRequired)
        XCTAssertTrue(calls.values.isEmpty, "Unconfirmed local edits must be skipped by the sheet")
        XCTAssertEqual(try fixture.files.readFile(at: fixture.root + "/skills/handoff-drift/SKILL.md"), "old body\n")
        sheet.setDriftConfirmation(true, for: rows[0])
        await sheet.applySelectedAndReport(context: fixture.context)
        XCTAssertEqual(calls.values, [true], "The checked replace box authorizes the sheet's apply")
        XCTAssertNotNil(preview.selectedFile, "Sheet results never close the independent preview")
    }

    private func handoffLoaded(_ preview: ViewChangesViewModel) async {
        await TestWait.until(failureMessage: "hand-off preview did not load") { preview.state != .loading }
        XCTAssertNotNil(preview.selectedFile)
    }
}
