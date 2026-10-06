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
