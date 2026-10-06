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

        try await assertUnloadedHandoffsOnlyForward(fixture, routing, first: first, second: second.id, calls: calls,
                                              forwards: { opened.filter { $0 == "main" }.count })
        await assertLoadedSheetKeepsSelection(routing, first: first, second: second.id, calls: calls)

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

        try await assertApplyingHandoff(routing: routing, first: first.id, second: second.id,
                                   calls: calls, sync: (started, release), forwards: { opened.filter { $0 == "main" }.count })
    }

    private func assertUnloadedHandoffsOnlyForward(
        _ fixture: UpdateReviewFixture, _ routing: UpdateReviewRouting,
        first: Skill, second: UUID, calls: UpdateReviewRecorder<UUID>, forwards: () -> Int
    ) async throws {
        let sheet = routing.updates
        sheet.reset()
        routing.banner(for: first).onUpdate()
        let before = forwards()
        routing.window.onUpdate()
        XCTAssertEqual(forwards(), before + 1, "An idle open sheet only comes forward")
        await sheet.loadAndReport(context: routing.context)
        XCTAssertEqual(sheet.selectedSkillIDs, [first.id], "An idle open hand-off must not queue selection")
        let rows = sheet.rows
        sheet.reset()
        routing.banner(for: first).onUpdate()
        let selection = sheet.selectedSkillIDs
        let seed = sheet.initialSelection
        sheet.load(context: routing.context)
        let load = try XCTUnwrap(sheet.operationTask)
        let operation = try XCTUnwrap(sheet.operationID)
        XCTAssertTrue(sheet.isLoading)
        let loadingForwards = forwards()
        routing.window.onUpdate()
        XCTAssertEqual(forwards(), loadingForwards + 1, "A loading sheet only comes forward")
        XCTAssertEqual(sheet.selectedSkillIDs, selection, "A loading hand-off must not change selection")
        XCTAssertEqual(sheet.initialSelection, seed, "A loading hand-off must not queue selection")
        XCTAssertEqual(sheet.operationID, operation, "A hand-off cannot replace a loading operation")
        await TestWait.forTask(load, failureMessage: "hand-off sheet load did not finish")
        XCTAssertEqual(sheet.selectedSkillIDs, [first.id], "A loading hand-off preserves presentation selection")
        XCTAssertNotNil(routing.preview.selectedFile, "The preview stays open while the sheet loads")
        try await assertLoadErrorHandoff(fixture: fixture, rows: rows, preview: routing.preview,
                                         initialSkillID: first.id, windowSkillID: second)
        XCTAssertTrue(calls.values.isEmpty, "Unloaded hand-offs never apply")
    }

    private func assertLoadErrorHandoff(
        fixture: UpdateReviewFixture, rows: [UpdatesRow], preview: ViewChangesViewModel,
        initialSkillID: UUID, windowSkillID: UUID
    ) async throws {
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
        XCTAssertNotEqual(initialSkillID, windowSkillID, "The hand-off targets a different skill")
        XCTAssertEqual(preview.requestedSkillID, windowSkillID)
        routing.presentUpdates(skillID: initialSkillID)
        await sheet.loadAndReport(context: fixture.context)
        let error = sheet.loadPhase
        XCTAssertEqual(error, .failed(SkillUpdateFlowError.repositoryChanged.localizedDescription))
        let selection = sheet.selectedSkillIDs
        let seed = sheet.initialSelection
        let before = forwards
        routing.window.onUpdate()
        XCTAssertEqual(forwards, before + 1, "A load-error sheet only comes forward")
        XCTAssertEqual(sheet.selectedSkillIDs, selection, "A load-error hand-off must not change selection")
        XCTAssertEqual(sheet.initialSelection, seed, "A load-error hand-off must not queue selection")
        XCTAssertEqual(sheet.loadPhase, error, "A hand-off leaves the load error visible")
        sheet.load(context: fixture.context) // The production Retry action.
        let retry = try XCTUnwrap(sheet.operationTask)
        await TestWait.forTask(retry, failureMessage: "hand-off Retry did not finish")
        XCTAssertEqual(sheet.loadPhase, .loaded)
        XCTAssertEqual(sheet.selectedSkillIDs, [initialSkillID], "Retry uses the original presentation selection")
        XCTAssertTrue(applies.values.isEmpty, "A load-error hand-off and Retry never apply")
        XCTAssertNotNil(preview.selectedFile)
    }

    private func assertLoadedSheetKeepsSelection(
        _ routing: UpdateReviewRouting, first: Skill, second: UUID, calls: UpdateReviewRecorder<UUID>
    ) async {
        let sheet = routing.updates
        sheet.reset()
        routing.banner(for: first).onUpdate()
        await sheet.loadAndReport(context: routing.context)
        routing.window.onUpdate()
        XCTAssertEqual(sheet.selectedSkillIDs, [first.id, second], "A loaded hand-off adds its row")
        await sheet.loadAndReport(context: routing.context)
        XCTAssertEqual(sheet.selectedSkillIDs, [first.id, second], "A loaded sheet keeps the accepted hand-off")
        sheet.reset()
        routing.presentUpdates()
        await sheet.loadAndReport(context: routing.context)
        sheet.selectedSkillIDs = [first.id]
        await sheet.loadAndReport(context: routing.context)
        XCTAssertEqual(sheet.selectedSkillIDs, [first.id], "A loaded sheet keeps the current checked choices")
        XCTAssertTrue(calls.values.isEmpty, "A loaded hand-off and a repeated load request never apply")
    }

    private func assertApplyingHandoff(routing: UpdateReviewRouting, first: UUID, second: UUID,
                                       calls: UpdateReviewRecorder<UUID>, sync: (DispatchSemaphore, TestWait.Gate),
                                       forwards: () -> Int) async throws {
        let sheet = routing.updates, preview = routing.preview
        sheet.selectedSkillIDs = [first]
        sheet.applySelected(context: routing.context)
        let apply = try XCTUnwrap(sheet.operationTask)
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
        await TestWait.forTask(apply, failureMessage: "hand-off sheet apply did not settle")
        XCTAssertFalse(sheet.isApplying)
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
