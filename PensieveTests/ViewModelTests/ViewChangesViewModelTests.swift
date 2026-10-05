import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ViewChangesViewModelTests: XCTestCase {
    var fixture: UpdateReviewFixture!

    override func setUpWithError() throws { fixture = try UpdateReviewFixture() }
    override func tearDownWithError() throws { try fixture.cleanup() }

    func testFileSelectionUsesComputedHunksCountsAndIncompleteResult() async throws {
        let skill = try fixture.skill("first")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let preview = UpdateReviewFixture.preview()
        let model = ViewChangesViewModel(operations: fixture.operations(rows: [row], preview: preview))
        model.open(skillID: skill.id, context: fixture.context)
        XCTAssertEqual(model.state, .loading)
        XCTAssertFalse(model.canUpdate)
        await loaded(model)
        XCTAssertEqual(model.files, preview.files)
        XCTAssertEqual(model.selectedFile, preview.files[0])
        XCTAssertEqual(model.selectedFile?.linesAdded, 2)
        XCTAssertEqual(model.selectedFile?.linesRemoved, 1)
        XCTAssertEqual(model.selectedFile?.diff?.hunks.first?.header, "@@ -1,1 +1,2 @@")
        XCTAssertEqual(model.state, .loaded(preview))
        model.selectFile(path: "scripts/setup.sh")
        XCTAssertEqual(model.selectedFile, preview.files[1])
        XCTAssertEqual(model.selectedFile?.diff?.hunks.first?.lines.first?.newLineNumber, 1)
        model.selectFile(path: "missing")
        XCTAssertEqual(model.selectedFile, preview.files[1])
        XCTAssertEqual(ViewChangesPresentation.incompleteNote(preview.unreadFileCount),
                       "Preview incomplete: 3 files weren't read. View the remaining changes on GitHub.")
    }

    func testSwitchCancelsWorkerAndDropsItsLateResultAfterSecondPreviewLoads() async throws {
        let first = try fixture.skill("first")
        let second = try fixture.skill("second")
        let rows = try [first, second].map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: false) }
        let gate = TestWait.Gate(owner: self)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let cancelled = UpdateReviewRecorder<Bool>()
        let model = ViewChangesViewModel(operations: fixture.operations(rows: rows, diff: { id, _, _, _ in
            if id == first.id {
                started.signal()
                try gate.wait()
                cancelled.append(Task.isCancelled)
                finished.signal()
                return PinnedSkillDiff(comparison: FileTreeComparison(changes: [
                    FileTreeChange(path: "late-first", kind: .modified, content: .binary)
                ], unreadFileCount: 0, bytesRead: 0))
            }
            return UpdateReviewFixture.preview()
        }))
        model.open(skillID: first.id, context: fixture.context)
        let didStart = await TestWait.forSemaphore(started)
        XCTAssertTrue(didStart)
        model.open(skillID: second.id, context: fixture.context)
        await loaded(model)
        XCTAssertEqual(model.row?.id, second.id)
        let secondState = model.state
        gate.open()
        let didFinish = await TestWait.forSemaphore(finished)
        XCTAssertTrue(didFinish)
        await TestWait.until(failureMessage: "cancel observation missing") { !cancelled.values.isEmpty }
        XCTAssertEqual(cancelled.values, [true])
        XCTAssertEqual(model.state, secondState)
        XCTAssertFalse(model.files.contains { $0.path == "late-first" })
    }

    func testSheetResetDoesNotTouchPreviewOrFileSelection() async throws {
        let skill = try fixture.skill("retained")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let (sheet, model) = fixture.review(rows: [row])
        model.open(skillID: skill.id, context: fixture.context)
        await loaded(model)
        model.selectFile(path: "scripts/setup.sh")
        let state = model.state
        sheet.reset()
        XCTAssertEqual(model.state, state)
        XCTAssertEqual(model.selectedFilePath, "scripts/setup.sh")
        XCTAssertTrue(model.canUpdate)
    }

    func testDeletedUpdatedAndNoUpdateStatesRetirePreviewAndDisableApply() async throws {
        let skill = try fixture.skill("stale")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let model = ViewChangesViewModel(operations: fixture.operations(rows: [row]))
        for mutation in 0..<4 {
            skill.updateAvailable = true
            model.open(skillID: skill.id, context: fixture.context)
            await loaded(model)
            var skills = [skill]
            var revisions: [String: UInt64] = [:]
            switch mutation {
            case 0: skills = []
            case 1: skill.updatedAt = skill.updatedAt.addingTimeInterval(1)
            case 2: skill.updateAvailable = false
            default: revisions[skill.directoryName] = 1
            }
            model.validate(skills: skills, folderRevisions: revisions)
            guard case let .stale(message) = model.state else { return XCTFail("Expected stale state for \(mutation)") }
            XCTAssertFalse(message.isEmpty)
            XCTAssertNil(model.selectedFile)
            XCTAssertTrue(model.files.isEmpty)
            XCTAssertFalse(model.canUpdate)
        }
    }

    func testPreviewFailuresHaveRetryAndReloadTheSamePin() async throws {
        let skill = try fixture.skill("retry")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        for message in ["Authentication failed", "Network offline", "Repository moved", "Refused scripts/link"] {
            let calls = UpdateReviewRecorder<String>()
            let model = ViewChangesViewModel(operations: fixture.operations(rows: [row], diff: { _, commit, tree, _ in
                calls.append(commit + ":" + tree)
                if calls.values.count == 1 { throw PreviewFailure(message: message) }
                return UpdateReviewFixture.preview()
            }))
            model.open(skillID: skill.id, context: fixture.context)
            await loaded(model)
            XCTAssertEqual(model.state, .failed(message))
            XCTAssertFalse(model.canUpdate)
            model.retry(context: fixture.context)
            await loaded(model)
            XCTAssertNotNil(model.selectedFile)
            XCTAssertEqual(calls.values, Array(repeating: row.upstreamCommit + ":" + row.upstreamTree, count: 2))
        }
    }

    func testBannerSelectionKeepsOnlyRequestedDriftedSkillAndStillRequiresReplacement() async throws {
        let first = try fixture.skill("first")
        let second = try fixture.skill("second")
        let rows = try [first, second].map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: true) }
        let calls = UpdateReviewRecorder<UUID>()
        let sheet = fixture.sheet(rows: rows, apply: { id, _, _, _, _, _ in
            calls.append(id)
            throw SkillUpdateFlowError.repositoryChanged
        })
        sheet.present(selecting: second.id, library: fixture.library)
        XCTAssertTrue(sheet.isPresented)
        await sheet.loadAndReport(context: fixture.context)
        XCTAssertEqual(sheet.selectedSkillIDs, [second.id])
        await sheet.applySelectedAndReport(context: fixture.context)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertEqual(sheet.status(for: rows[1]), .confirmationRequired)
        XCTAssertEqual(sheet.status(for: rows[0]), .idle)
    }

    func testDraftCancellationPrecedesAnyReplacementQuestionOrApply() async throws {
        for drifted in [true, false] {
            let skill = try fixture.skill(drifted ? "draft-drifted" : "draft-clean")
            let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: drifted)
            let calls = UpdateReviewRecorder<UUID>()
            let model = ViewChangesViewModel(operations: fixture.operations(rows: [row], apply: { id, _, _, _, _, _ in
                calls.append(id)
                throw SkillUpdateFlowError.repositoryChanged
            }))
            fixture.library.setLastWrittenBody("old body\n", directoryName: skill.directoryName)
            fixture.library.noteEditorChanged(skill, body: "unsaved draft")
            var answer: ((UnsavedChangesChoice) -> Void)?
            fixture.library.unsavedChangesPresenter = { _, resolve in answer = resolve }
            model.open(skillID: skill.id, context: fixture.context)
            await loaded(model)
            XCTAssertTrue(fixture.library.hasUnsavedChanges)
            XCTAssertNil(answer, "opening a preview must not leave the draft")
            model.requestUpdate(library: fixture.library, context: fixture.context,
                                onSuccess: { XCTFail("Cancelled update closed") })
            XCTAssertNotNil(answer)
            XCTAssertTrue(calls.values.isEmpty)
            XCTAssertFalse(model.asksToReplaceLocalEdits)
            answer?(.cancel)
            XCTAssertFalse(model.asksToReplaceLocalEdits, "Cancel must not ask to replace local edits")
            await Task.yield()
            XCTAssertFalse(model.isPreparingUpdate)
            XCTAssertFalse(model.isApplying, "Cancel must never reserve an apply")
            XCTAssertTrue(fixture.library.hasUnsavedChanges)
            XCTAssertTrue(calls.values.isEmpty)
        }
    }

    func testDriftConfirmationDeclinePreservesBytesAndConfirmationAllowsApply() async throws {
        let skill = try fixture.skill("drift")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: true)
        let flags = UpdateReviewRecorder<Bool>()
        let model = ViewChangesViewModel(operations: fixture.operations(rows: [row], apply: { _, _, _, flag, _, _ in
            flags.append(flag)
            throw SkillUpdateFlowError.repositoryChanged
        }))
        model.open(skillID: skill.id, context: fixture.context)
        await loaded(model)
        model.requestUpdate(library: fixture.library, context: fixture.context, onSuccess: {})
        XCTAssertTrue(model.asksToReplaceLocalEdits)
        XCTAssertTrue(flags.values.isEmpty)
        model.confirmReplacement(false, library: fixture.library, context: fixture.context, onSuccess: {})
        XCTAssertTrue(flags.values.isEmpty)
        XCTAssertEqual(try fixture.files.readFile(at: fixture.root + "/skills/drift/SKILL.md"), "old body\n")
        model.requestUpdate(library: fixture.library, context: fixture.context, onSuccess: {})
        model.asksToReplaceLocalEdits = false // SwiftUI dismisses an alert's binding before its button action.
        model.confirmReplacement(true, library: fixture.library, context: fixture.context, onSuccess: {})
        await TestWait.until(failureMessage: "confirmed apply did not finish") { !model.isApplying }
        XCTAssertEqual(flags.values, [true])
        XCTAssertEqual(model.applyMessage, SkillUpdateFlowError.repositoryChangedMessage)
        XCTAssertTrue(model.canUpdate)
    }

    func testPresentationReasonsDistinguishBinarySizeBudgetAndModeWithoutInventingCounts() {
        let cases: [(FileTreeChange.Content, String)] = [
            (.binary, "binary"), (.tooLarge, "too large"), (.diffBudgetExhausted, "diff budget"),
            (.modeOnly(old: 0, new: 0o100), "off to on")
        ]
        for (content, expected) in cases {
            let file = PinnedSkillFileDiff(change: FileTreeChange(path: "file", kind: .modified, content: content))
            XCTAssertTrue(ViewChangesPresentation.unavailableReason(file)?.contains(expected) == true)
            if case .modeOnly = content {
                XCTAssertNil(ViewChangesPresentation.sidebarCounts(file), "Mode changes have no line counts")
                XCTAssertEqual(ViewChangesPresentation.summary(file), "Permissions changed")
                XCTAssertEqual(ViewChangesPresentation.unavailableTitle(file), "Permissions Changed")
            } else {
                XCTAssertNil(file.linesAdded)
                XCTAssertNil(file.linesRemoved)
            }
        }
        let line = UnifiedDiffLine(kind: .added, text: "keep\r\n", oldLineNumber: nil, newLineNumber: 1)
        XCTAssertEqual(ViewChangesPresentation.lineText(line), "keep")
        XCTAssertEqual(ViewChangesPresentation.lineText(UnifiedDiffLine(
            kind: .context, text: "lone\rinside", oldLineNumber: 1, newLineNumber: 1)), "lone\rinside")
    }

    private func loaded(_ model: ViewChangesViewModel) async {
        await TestWait.until(failureMessage: "preview did not finish") { model.state != .loading }
    }
}

private struct PreviewFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
