import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

extension ViewChangesViewModelTests {
    func testPresentationMakesHiddenLineAndFilenameScalarsVisible() throws {
        // Sweep the independent Unicode contract, including every assigned format character.
        let categories: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator]
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value), categories.contains(scalar.properties.generalCategory),
                  value != 9, value != 10 else { continue }
            let mark = value == 13 ? "␍" : String(format: "⟨U+%04X⟩", value)
            let line = UnifiedDiffLine(kind: .added, text: "before" + String(scalar) + "after\n",
                                       oldLineNumber: nil, newLineNumber: 1)
            let shown = ViewChangesPresentation.lineText(line)
            XCTAssertEqual(String(shown.characters), "before" + mark + "after", "Hidden scalars must remain visible")
            XCTAssertEqual(shown.runs.filter { $0.foregroundColor != nil }.count, 1,
                           "Each hidden scalar needs a distinctly styled mark")
            let name = ViewChangesPresentation.styledText("name" + String(scalar) + ".txt", filename: true)
            XCTAssertEqual(String(name.characters), "name" + mark + ".txt", "Names use the same category rule")
            XCTAssertEqual(name.runs.filter { $0.foregroundColor != nil }.count, 1)
        }
        let literal = UnifiedDiffLine(kind: .added, text: "␍ ⟨U+FEFF⟩\n", oldLineNumber: nil, newLineNumber: 1)
        XCTAssertEqual(String(ViewChangesPresentation.lineText(literal).characters), "␍ ⟨U+FEFF⟩")
        XCTAssertTrue(ViewChangesPresentation.lineText(literal).runs.allSatisfy { $0.foregroundColor == nil },
                      "Literal marker text must not be styled as a hidden character")
        let bom = UnifiedDiff(old: "body\n", new: "\u{FEFF}body\n")
        let bomLine = try XCTUnwrap(bom.hunks.first?.lines.last)
        XCTAssertEqual(String(ViewChangesPresentation.lineText(bomLine).characters), "⟨U+FEFF⟩body",
                       "A BOM-only change must visibly show its BOM")
        let tab = UnifiedDiffLine(kind: .context, text: "a\tb\n", oldLineNumber: 1, newLineNumber: 1)
        XCTAssertEqual(String(ViewChangesPresentation.lineText(tab).characters), "a\tb", "Tabs remain literal")
        for (path, visible) in [("folder/evil\u{202E}.txt", "evil⟨U+202E⟩.txt"),
                                ("folder/first\nlast", "first⟨U+000A⟩last"), ("folder/tab\tname", "tab\tname")] {
            let file = try XCTUnwrap(PinnedSkillDiff.build(comparison: FileTreeComparison(changes: [
                FileTreeChange(path: path, kind: .added, content: .binary)
            ], unreadFileCount: 0, bytesRead: 0)).files.first)
            XCTAssertEqual(ViewChangesPresentation.filePath(file), "folder/" + visible)
            XCTAssertEqual(ViewChangesPresentation.accessibilityLabel(file), visible + ", folder, Binary file")
        }
        try assertLineEndingNotes()
    }

    private func assertLineEndingNotes() throws {
        let diff = UnifiedDiff(old: "context\r\nending\r\n", new: "context\r\nending\ntail")
        let lines = try XCTUnwrap(diff.hunks.first).lines
        XCTAssertEqual(String(ViewChangesPresentation.lineText(lines[0]).characters), "context")
        XCTAssertTrue(ViewChangesPresentation.lineText(lines[0]).runs.allSatisfy { $0.foregroundColor == nil })
        XCTAssertEqual(ViewChangesPresentation.lineNotes(lines), [2: ["Line ending changed: CRLF → LF"],
                                                                3: ["\\ No newline at end of file"]],
                       "Line-ending facts must be separate note rows after their affected lines")
        XCTAssertEqual(lines.map { String(ViewChangesPresentation.lineText($0).characters) },
                       ["context", "ending", "ending", "tail"], "Note text must never enter diff lines")
    }

    func testCRLFContextAndLineEndingChangesRemainReadable() throws {
        let context = UnifiedDiff(old: "same\r\nold\r\n", new: "same\r\nnew\r\n")
        let lines = try XCTUnwrap(context.hunks.first).lines
        XCTAssertEqual(String(ViewChangesPresentation.lineText(lines[0]).characters), "same")
        XCTAssertFalse(lines.map { String(ViewChangesPresentation.lineText($0).characters) }.contains { $0.contains("␍") })
        let ending = UnifiedDiff(old: "same\n", new: "same\r\n")
        let changed = try XCTUnwrap(ending.hunks.first).lines
        XCTAssertEqual(changed.map { String(ViewChangesPresentation.lineText($0).characters) }, ["same", "same"])
        XCTAssertEqual(ViewChangesPresentation.lineNotes(changed), [1: ["Line ending changed: LF → CRLF"]],
                       "An ending-only change must have one separate note")
        for text in ["a\rb\n", "last\r"] {
            let line = UnifiedDiffLine(kind: .added, text: text, oldLineNumber: nil, newLineNumber: 1)
            XCTAssertTrue(String(ViewChangesPresentation.lineText(line).characters).contains("␍"))
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
            let skill = try fixture.skill("busy-" + outcome)
            let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
            let started = DispatchSemaphore(value: 0)
            let release = TestWait.Gate(owner: self)
            let checks = UpdateReviewRecorder<UUID>()
            let commit = String(repeating: "4", count: 40)
            let other = try fixture.skill("unrelated-" + outcome)
            let sheetRow = outcome == "other" ? try UpdatesViewModel.makeRow(skill: other, driftedLocally: false) : row
            let sheet = blockedSheet(row: sheetRow, applied: try appliedCompletion(skill: skill, row: row),
                                     started: started, release: release, commit: commit, outcome: outcome)
            let window = ViewChangesViewModel(library: fixture.library,
                operations: fixture.operations(rows: [row], diff: { _, _ in throw SkillUpdateFlowError.repositoryChanged },
                    recheck: { id, _ in
                        checks.append(id)
                        return SkillUpdateRecheckCompletion(row: row, skillID: id, updateAvailable: true,
                            lastCheckedAt: Date(), lastCheckedHead: commit, upstreamTree: "window-tree",
                            upstreamCommit: commit, upstreamCommitDate: row.updateDate, checkError: nil)
                    }), updates: sheet)
            sheet.present(library: fixture.library)
            await sheet.loadAndReport(context: fixture.context)
            window.open(skillID: skill.id, context: fixture.context)
            await TestWait.until(failureMessage: "preview failure did not arrive") { window.state != .loading }
            XCTAssertTrue(window.canRecheck)
            if outcome == "checked" { sheet.recheck(row, context: fixture.context) } else {
                sheet.applySelected(context: fixture.context)
            }
            let task = try XCTUnwrap(sheet.operationTask)
            let didStart = await TestWait.forSemaphore(started)
            XCTAssertTrue(didStart)
            if outcome == "other" {
                XCTAssertTrue(window.canRecheck, "Unrelated sheet work must not disable this skill's Re-check")
            } else {
                XCTAssertFalse(window.canRecheck, "Re-check must be unavailable during same-skill sheet work")
                window.recheck(context: fixture.context)
                XCTAssertFalse(window.isRechecking, "An unavailable Re-check must not queue a waiter")
                skill.updatedAt = skill.updatedAt.addingTimeInterval(1)
                window.validate(skills: [skill], folderRevisions: [:], context: fixture.context)
                XCTAssertFalse(window.canRecheck, "Identity invalidation during sheet work must keep Re-check unavailable")
            }
            release.open()
            await TestWait.forTask(task, failureMessage: "sheet worker did not finish")
            window.validate(skills: [skill], folderRevisions: [:], context: fixture.context)
            assertSheetResult(window, skill: skill, row: row, outcome: outcome, checks: checks, commit: commit)
            window.recheck(context: fixture.context)
            await TestWait.until(failureMessage: "explicit window check did not settle") { !window.isRechecking }
            XCTAssertEqual(checks.values, [skill.id], "Only a new explicit Re-check may start a window worker")
        }
    }

    private func assertSheetResult(_ window: ViewChangesViewModel, skill: Skill, row: UpdatesRow, outcome: String,
                                   checks: UpdateReviewRecorder<UUID>, commit: String) {
        XCTAssertTrue(window.canRecheck, "Re-check must become available after sheet completion and identity changes")
        XCTAssertEqual(checks.values, [], "No deferred window check may overwrite the sheet's result")
        XCTAssertEqual(skill.updateAvailable, outcome != "applied")
        XCTAssertEqual(skill.upstreamCommit,
                       outcome == "applied" ? nil : outcome == "checked" ? commit : row.upstreamCommit)
        XCTAssertEqual(skill.upstreamTree,
                       outcome == "applied" ? nil : outcome == "checked" ? "sheet-tree" : row.upstreamTree)
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
