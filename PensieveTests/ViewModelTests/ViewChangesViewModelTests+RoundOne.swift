import SwiftData
import XCTest
@testable import Pensieve

extension ViewChangesViewModelTests {
    func testWindowRecheckCoordinationDoesNotPollTheMainActor() async throws {
        // Architecture contract: the auxiliary window must not schedule periodic sheet probes.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("Pensieve/ViewModels/ViewChangesViewModel.swift").path
        let source = try FileService().readFile(at: path)
        XCTAssertFalse(source.contains("Task.sleep"), "Window coordination must await sheet completion without a polling timer")
        let skill = try fixture.skill("cancelled-wait")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let started = DispatchSemaphore(value: 0)
        let release = TestWait.Gate(owner: self)
        let sheet = blockedSheet(row: row, applied: try appliedCompletion(skill: skill, row: row),
                                 started: started, release: release, commit: row.upstreamCommit, outcome: "applied")
        await sheet.loadAndReport(context: fixture.context)
        sheet.applySelected(context: fixture.context)
        let applyTask = try XCTUnwrap(sheet.operationTask)
        let didStart = await TestWait.forSemaphore(started)
        XCTAssertTrue(didStart)
        let wait = Task {
            do {
                try await sheet.waitForCompletion(affecting: skill.id)
                XCTFail("A cancelled completion wait must throw")
            } catch is CancellationError {
                // Cancellation belongs to the waiter, leaving the sheet's operation running.
            } catch { XCTFail("Unexpected wait failure: \(error)") }
        }
        wait.cancel()
        await TestWait.forTask(wait, failureMessage: "Cancelled completion wait retained the blocked worker")
        XCTAssertTrue(sheet.isApplying, "Cancelling a waiter must not cancel the sheet's apply")
        release.open()
        await TestWait.forTask(applyTask, failureMessage: "Owned apply did not finish")
    }

    func testPresentationMakesHiddenLineAndFilenameScalarsVisible() throws {
        let values: [UInt32] = Array(0...8) + Array(11...31) + Array(0x7F...0x9F)
            + [0x2028, 0x2029, 0x200E, 0x200F, 0x061C] + Array(0x202A...0x202E)
            + Array(0x2066...0x2069) + Array(0xE0000...0xE007F)
        for value in values {
            let scalar = try XCTUnwrap(Unicode.Scalar(value))
            let mark = value == 13 ? "␍" : String(format: "⟨U+%04X⟩", value)
            let line = UnifiedDiffLine(kind: .added, text: "before" + String(scalar) + "after\n",
                                       oldLineNumber: nil, newLineNumber: 1)
            XCTAssertTrue(ViewChangesPresentation.lineText(line) == "before" + mark + "after",
                           "Hidden scalars must remain visible in the exact presentation rendered by the diff")
        }
        let tab = UnifiedDiffLine(kind: .context, text: "a\tb\n", oldLineNumber: 1, newLineNumber: 1)
        XCTAssertEqual(ViewChangesPresentation.lineText(tab), "a\tb", "Tabs remain literal in diff lines")
        for (path, visible) in [("folder/evil\u{202E}.txt", "evil⟨U+202E⟩.txt"),
                                ("folder/first\nlast", "first⟨U+000A⟩last"),
                                ("folder/tab\tname", "tab⟨U+0009⟩name")] {
            let file = try XCTUnwrap(PinnedSkillDiff.build(comparison: FileTreeComparison(changes: [
                FileTreeChange(path: path, kind: .added, content: .binary)
            ], unreadFileCount: 0, bytesRead: 0)).files.first)
            XCTAssertEqual(ViewChangesPresentation.filePath(file), "folder/" + visible,
                           "The file header must use the same visible marks as its sidebar")
            XCTAssertEqual(ViewChangesPresentation.accessibilityLabel(file), visible + ", folder, Binary file",
                           "Filename controls must be visible in the sidebar and header presentation")
        }
    }

    func testCRLFContextAndLineEndingChangesRemainReadable() throws {
        let context = UnifiedDiff(old: "same\r\nold\r\n", new: "same\r\nnew\r\n")
        let lines = try XCTUnwrap(context.hunks.first).lines
        XCTAssertEqual(ViewChangesPresentation.lineText(lines[0]), "same", "CRLF context must not show a CR mark")
        XCTAssertFalse(lines.map(ViewChangesPresentation.lineText).contains { $0.contains("␍") })
        let ending = UnifiedDiff(old: "same\n", new: "same\r\n")
        let changed = try XCTUnwrap(ending.hunks.first).lines.map(ViewChangesPresentation.lineText)
        XCTAssertNotEqual(changed[0], changed[1], "An LF-to-CRLF change must have a visible line ending difference")
        for text in ["a\rb\n", "last\r"] {
            let line = UnifiedDiffLine(kind: .added, text: text, oldLineNumber: nil, newLineNumber: 1)
            XCTAssertTrue(ViewChangesPresentation.lineText(line).contains("␍"), "A CR outside CRLF must be marked")
        }
    }

    func testReopeningTheSameLoadedIdentityDoesNotReloadPreview() async throws {
        let skill = try fixture.skill("same-preview")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let calls = UpdateReviewRecorder<UUID>()
        let model = ViewChangesViewModel(library: fixture.library,
            operations: fixture.operations(rows: [row], diff: { request, _ in
                calls.append(request.id)
                return UpdateReviewFixture.preview()
            }))
        model.open(skillID: skill.id, context: fixture.context)
        await TestWait.until(failureMessage: "initial preview did not finish") { model.state != .loading }
        model.selectFile(path: "scripts/setup.sh")
        let loaded = model.state
        model.open(skillID: skill.id, context: fixture.context)
        XCTAssertEqual(model.state, loaded, "Opening a loaded unchanged identity must only bring its window forward")
        await TestWait.until(failureMessage: "reopened preview did not finish") { model.state != .loading }
        XCTAssertEqual(calls.values, [skill.id], "A loaded unchanged preview must not clone again")
        XCTAssertEqual(model.selectedFilePath, "scripts/setup.sh")
        skill.updatedAt = skill.updatedAt.addingTimeInterval(1)
        model.open(skillID: skill.id, context: fixture.context)
        await TestWait.until(failureMessage: "changed preview did not finish") { model.state != .loading }
        XCTAssertEqual(calls.values, [skill.id, skill.id], "Changed identities still need a fresh preview")
    }
    func testWindowRecheckWaitsForSheetAndKeepsItsApplyOrRecheckResult() async throws {
        for outcome in ["applied", "checked", "failed", "other"] {
            let apply = outcome != "checked"
            let skill = try fixture.skill("busy-" + outcome)
            let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
            let applied = try appliedCompletion(skill: skill, row: row)
            let started = DispatchSemaphore(value: 0)
            let release = TestWait.Gate(owner: self)
            let checks = UpdateReviewRecorder<UUID>()
            let diffs = UpdateReviewRecorder<String>()
            let newCommit = String(repeating: "4", count: 40)
            let other = try fixture.skill("unrelated-" + outcome)
            let sheetRow = outcome == "other" ? try UpdatesViewModel.makeRow(skill: other, driftedLocally: false) : row
            let sheet = blockedSheet(row: sheetRow, applied: applied, started: started, release: release,
                                     commit: newCommit, outcome: outcome)
            let window = ViewChangesViewModel(library: fixture.library,
                operations: fixture.operations(rows: [row], diff: { request, _ in
                    diffs.append(request.upstreamCommit)
                    if diffs.values.count == 1 { throw SkillUpdateFlowError.repositoryChanged }
                    return UpdateReviewFixture.preview()
                }, recheck: { id, _ in
                    checks.append(id)
                    return SkillUpdateRecheckCompletion(row: row, skillID: id, updateAvailable: true,
                        lastCheckedAt: Date(), lastCheckedHead: newCommit, upstreamTree: "sheet-tree",
                        upstreamCommit: newCommit, upstreamCommitDate: row.updateDate, checkError: nil)
                }), updates: sheet)
            sheet.present(library: fixture.library)
            await sheet.loadAndReport(context: fixture.context)
            window.open(skillID: skill.id, context: fixture.context)
            await TestWait.until(failureMessage: "preview failure did not arrive") { window.state != .loading }
            if apply { sheet.applySelected(context: fixture.context) } else { sheet.recheck(row, context: fixture.context) }
            let task = try XCTUnwrap(sheet.operationTask)
            let didStart = await TestWait.forSemaphore(started)
            XCTAssertTrue(didStart)
            window.recheck(context: fixture.context)
            try await Task.sleep(for: .milliseconds(80))
            if outcome != "other" {
                XCTAssertTrue(checks.values.isEmpty, "The window must hold Re-check while the sheet's worker is blocked")
            }
            if outcome != "other" { XCTAssertTrue(window.isRechecking) }
            release.open()
            await TestWait.forTask(task, failureMessage: "sheet worker did not finish")
            await TestWait.until(failureMessage: "held window check did not settle") { !window.isRechecking }
            await assertRecheckResult(window: window, skill: skill, outcome: outcome, checks: checks, commit: newCommit)
        }
    }

    private func assertRecheckResult(window: ViewChangesViewModel, skill: Skill, outcome: String,
                                     checks: UpdateReviewRecorder<UUID>, commit: String) async {
        XCTAssertEqual(checks.values, outcome == "applied" ? [] : [skill.id],
                       "A waited Re-check must check upstream unless the sheet updated this skill")
        XCTAssertEqual(skill.updateAvailable, outcome != "applied")
        XCTAssertEqual(skill.upstreamCommit, outcome == "applied" ? nil : commit)
        XCTAssertEqual(skill.upstreamTree, outcome == "applied" ? nil : "sheet-tree")
        if outcome == "applied" { XCTAssertEqual(window.state, .stale("This skill was updated.")) } else {
            await TestWait.until(failureMessage: "the sheet pin did not reload") { window.state != .loading }
            XCTAssertEqual(window.row?.upstreamCommit, commit)
            XCTAssertNotNil(window.selectedFile)
        }
    }

    private func blockedSheet(row: UpdatesRow, applied: SkillUpdateCompletion, started: DispatchSemaphore,
                              release: TestWait.Gate, commit: String, outcome: String) -> UpdatesViewModel {
        UpdatesViewModel(rowLoader: { _ in [row] }, applyOperation: { _, _, _, _, _, _ in
            started.signal()
            try release.wait()
            if outcome == "failed" { throw SkillUpdateFlowError.repositoryChanged }
            if outcome == "other" {
                return SkillUpdateCompletion(skillID: row.id, name: "Other", skillDescription: "Other",
                    installedOriginData: applied.installedOriginData, updatedAt: Date())
            }
            return applied
        }, recheckOperation: { id, _ in
            started.signal()
            try release.wait()
            return SkillUpdateRecheckCompletion(row: row, skillID: id, updateAvailable: true,
                lastCheckedAt: Date(), lastCheckedHead: commit, upstreamTree: "sheet-tree",
                upstreamCommit: commit, upstreamCommitDate: row.updateDate, checkError: nil)
        })
    }

    private func appliedCompletion(skill: Skill, row: UpdatesRow) throws -> SkillUpdateCompletion {
        var origin = try XCTUnwrap(skill.installedOrigin)
        origin.installedCommit = row.upstreamCommit
        origin.installedTree = row.upstreamTree
        return SkillUpdateCompletion(skillID: skill.id, name: skill.name, skillDescription: skill.skillDescription,
            installedOriginData: try JSONEncoder().encode(origin), updatedAt: Date())
    }

}
