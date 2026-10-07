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
        let model = ViewChangesViewModel(library: fixture.library, operations: fixture.operations(rows: [row], preview: preview))
        model.open(skillID: skill.id, context: fixture.context)
        XCTAssertEqual(model.state, .loading)
        XCTAssertFalse(model.canUpdate)
        await loaded(model)
        XCTAssertEqual(ViewChangesPresentation.accessibilityLabel(preview.files[0]),
                       "SKILL.md, 2 additions, 1 deletion")
        XCTAssertEqual(ViewChangesPresentation.accessibilityLabel(preview.files[1]),
                       "setup.sh, scripts, 1 addition, 0 deletions")
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
        let model = ViewChangesViewModel(library: fixture.library,
            operations: fixture.operations(rows: rows, diff: { request, _ in
            if request.id == first.id {
                started.signal()
                try gate.wait()
                cancelled.append(Task.isCancelled)
                finished.signal()
                return try PinnedSkillDiff.build(comparison: FileTreeComparison(changes: [
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
        for mutation in 0..<4 {
            let skill = try fixture.skill("stale-\(mutation)")
            let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
            let model = ViewChangesViewModel(library: fixture.library, operations: fixture.operations(rows: [row]))
            skill.updateAvailable = true
            model.open(skillID: skill.id, context: fixture.context)
            await loaded(model)
            var skills = [skill]
            var revisions: [String: UInt64] = [:]
            switch mutation {
            case 0:
                fixture.context.delete(skill)
                try fixture.context.save()
                skills = []
            case 1: skill.updatedAt = skill.updatedAt.addingTimeInterval(1)
            case 2: skill.updateAvailable = false
            default: revisions[skill.directoryName] = 1
            }
            model.validate(skills: skills, folderRevisions: revisions, context: fixture.context)
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
        let errors: [(Error, Bool)] = [(SkillInstallError.authenticationFailed, false),
                                      (SkillInstallError.networkUnavailable, false),
                                      (SkillInstallError.unavailableCandidate("Refused scripts/link"), false),
                                      (SkillUpdateFlowError.repositoryChanged, true),
                                      (SkillUpdateFlowError.missingPinnedUpdate, true)]
        for (error, moved) in errors {
            let calls = UpdateReviewRecorder<String>()
            let checks = UpdateReviewRecorder<UUID>()
            let newCommit = String(repeating: "3", count: 40)
            skill.upstreamCommit = row.upstreamCommit
            skill.upstreamTree = row.upstreamTree
            skill.upstreamCommitDate = row.updateDate
            let model = ViewChangesViewModel(library: fixture.library,
                operations: fixture.operations(rows: [row], diff: { request, _ in
                    calls.append(request.upstreamCommit + ":" + request.upstreamTree)
                    if calls.values.count == 1 { throw error }
                    return UpdateReviewFixture.preview()
                }, recheck: { id, _ in
                    checks.append(id)
                    return SkillUpdateRecheckCompletion(row: row, skillID: id, updateAvailable: true,
                        lastCheckedAt: Date(), lastCheckedHead: newCommit, upstreamTree: "current-tree",
                        upstreamCommit: newCommit, upstreamCommitDate: row.updateDate, checkError: nil)
                }))
            model.open(skillID: skill.id, context: fixture.context)
            await loaded(model)
            XCTAssertEqual(model.state, .failed(UpdatesViewModel.readable(error)))
            XCTAssertFalse(model.canUpdate)
            XCTAssertEqual(model.canRecheck, moved, "Real pin errors need Re-check; auth, network and path errors need Retry")
            if moved { model.recheck(context: fixture.context) } else { model.retry(context: fixture.context) }
            await loaded(model)
            XCTAssertNotNil(model.selectedFile)
            XCTAssertEqual(checks.values, moved ? [skill.id] : [])
            XCTAssertEqual(calls.values, [row.upstreamCommit + ":" + row.upstreamTree,
                                         moved ? newCommit + ":current-tree" : row.upstreamCommit + ":" + row.upstreamTree],
                           "Retry reloads the same pin; Re-check loads the pin returned by the upstream check")
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

    func testPresentationReasonsDistinguishBinarySizeBudgetAndModeWithoutInventingCounts() throws {
        let cases: [(FileTreeChange.Content, String)] = [
            (.binary, "binary"), (.tooLarge, "too large"), (.diffBudgetExhausted, "diff budget"),
            (.modeOnly, "off to on")
        ]
        for (content, expected) in cases {
            let file = try XCTUnwrap(PinnedSkillDiff.build(comparison: FileTreeComparison(changes: [
                FileTreeChange(path: "file", kind: .modified, content: content,
                               permissions: content == .modeOnly ? .init(old: 0, new: 0o100) : nil)
            ], unreadFileCount: 0, bytesRead: 0)).files.first)
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
        XCTAssertEqual(ViewChangesPresentation.lineText(line), "keep ⟨CRLF line ending⟩")
        XCTAssertEqual(ViewChangesPresentation.lineText(UnifiedDiffLine(
            kind: .context, text: "lone\rinside", oldLineNumber: 1, newLineNumber: 1)), "lone␍inside")
    }

    private func loaded(_ model: ViewChangesViewModel) async {
        await TestWait.until(failureMessage: "preview did not finish") { model.state != .loading }
    }
}
