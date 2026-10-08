import SwiftData
import XCTest
@testable import Pensieve

extension UpdatesViewModelTests {
    func testSheetUpdateRetiresOpenPreviewWhileRefusalStaysOnSheet() async throws {
        let fixture = try prepareRealPinnedUpdate()
        let review = makeRealHandoff(fixture: fixture)
        let routing = review.routing, sheet = review.sheet, window = review.window, library = review.library
        routing.presentChanges(skillID: fixture.skill.id)
        await windowLoaded(window)
        let state = window.state
        let path = fixture.storeRoot + "/skills/vendor/SKILL.md"
        let before = try fileService.readData(at: path)
        routing.window.onUpdate()
        XCTAssertEqual(try fileService.readData(at: path), before, "The window hand-off writes nothing")
        await sheet.loadAndReport(context: context)
        let row = try XCTUnwrap(sheet.rows.first)
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: tempDir + "/sync.lock"))
        await sheet.applySelectedAndReport(context: context)
        lock.release()
        XCTAssertEqual(sheet.status(for: row), .failed(message: SkillInstallError.syncInProgress.localizedDescription,
                                                       offersRecheck: false))
        window.validate(skills: [fixture.skill], folderRevisions: library.folderChangeRevisions, context: context)
        XCTAssertEqual(window.state, state, "The sheet's refusal must not become a window result")
        XCTAssertTrue(window.canUpdate)
        XCTAssertEqual(try fileService.readData(at: path), before)
        await sheet.applySelectedAndReport(context: context)
        XCTAssertEqual(sheet.status(for: row), .updated)
        window.validate(skills: [fixture.skill], folderRevisions: library.folderChangeRevisions, context: context)
        XCTAssertEqual(window.state, .stale("This skill was updated."), "The installed target must retire its open preview")
        XCTAssertFalse(window.canUpdate, "Update must be disabled after the sheet installs this target")
        XCTAssertNil(window.selectedFile)
        XCTAssertEqual(window.requestedSkillID, fixture.skill.id, "The updated window stays open")
        XCTAssertEqual(fixture.skill.installedOrigin?.installedCommit, fixture.pinnedCommit)
        XCTAssertTrue(library.readBody(fixture.skill).contains("fresh body"))
        try await assertReplacementFailureStaysOnSheet(fixture: fixture)
    }

    func testWindowHandoffHonorsDirtyDraftCancelAndSettlesCleanDraftBeforeSheetApply() async throws {
        let fixture = try prepareRealPinnedUpdate()
        let review = makeRealHandoff(fixture: fixture)
        let routing = review.routing, sheet = review.sheet, window = review.window, library = review.library
        let oldBody = library.readBody(fixture.skill)
        library.setLastWrittenBody(oldBody, directoryName: fixture.skill.directoryName)
        library.noteEditorChanged(fixture.skill, body: "dirty draft")
        var answer: ((UnsavedChangesChoice) -> Void)?
        library.unsavedChangesPresenter = { _, resolve in answer = resolve }
        routing.presentChanges(skillID: fixture.skill.id)
        await windowLoaded(window)
        XCTAssertNil(answer, "Opening View Changes must leave a draft alone")
        routing.window.onUpdate()
        XCTAssertNotNil(answer, "The hand-off must ask about a dirty draft first")
        XCTAssertFalse(sheet.isPresented, "The sheet cannot open before the draft gate resolves")
        answer?(.cancel)
        XCTAssertFalse(sheet.isPresented, "Cancel leaves the sheet closed")
        XCTAssertTrue(library.hasUnsavedChanges)
        XCTAssertEqual(library.readBody(fixture.skill), oldBody, "Cancel must not apply")
        XCTAssertNotNil(window.selectedFile)

        library.discardDraft(fixture.skill)
        library.setLastWrittenBody("older baseline", directoryName: fixture.skill.directoryName)
        library.noteEditorChanged(fixture.skill, body: oldBody)
        library.setLastWrittenBody(oldBody, directoryName: fixture.skill.directoryName)
        XCTAssertNotNil(library.drafts[fixture.skill.directoryName])
        XCTAssertFalse(library.hasUnsavedChanges)
        routing.window.onUpdate()
        XCTAssertTrue(sheet.isPresented)
        XCTAssertNil(library.drafts[fixture.skill.directoryName], "The shared presentation gate settles clean retained drafts")
        await sheet.loadAndReport(context: context)
        XCTAssertEqual(sheet.selectedSkillIDs, [fixture.skill.id])
        await sheet.applySelectedAndReport(context: context)
        XCTAssertEqual(fixture.skill.installedOrigin?.installedCommit, fixture.pinnedCommit)
        XCTAssertFalse(fixture.skill.updateAvailable)
        XCTAssertEqual(fixture.skill.name, "Fresh Name")
        XCTAssertTrue(library.readBody(fixture.skill).contains("fresh body"))
        XCTAssertTrue(library.saveDraft(fixture.skill))
        XCTAssertTrue(library.readBody(fixture.skill).contains("fresh body"), "Save cannot reapply the retained old text")
        XCTAssertNotNil(window.requestedSkillID)
    }

    private func assertReplacementFailureStaysOnSheet(fixture: RealFixture) async throws {
        try fileService.writeFile(at: fixture.repository + "/skills/vendor/SKILL.md",
            content: "---\nname: Next\ndescription: Next update\n---\nnext body\n")
        fixture.skill.upstreamCommit = try commit(fixture.repository, message: "next pinned update")
        fixture.skill.upstreamTree = try TestPaths.git.treeHash(at: fixture.repository, path: "skills/vendor")
        fixture.skill.updateAvailable = true
        fixture.skill.upstreamCommitDate = Date(timeIntervalSince1970: 1_870_000_000)
        try context.save()
        let service = SkillInstallService(
            gitService: GitService(fileService: fileService, askpassHelperPath: TestPaths.gitAskpassHelperPath),
                credentialStore: InMemoryCredentialStore(),
            fileService: fileService, scratchRoot: tempDir + "/post-write", storeRoot: fixture.storeRoot,
            manifestService: CrashManifest(wrapped: ManifestService(fileService: fileService), failurePoint: .beforeUpsert),
            lockPath: tempDir + "/sync.lock", remoteValidator: { ValidatedInstallRemote(repo: $0, cloneRemote: $0) }
        )
        let review = makeRealHandoff(fixture: fixture, service: service)
        review.routing.presentChanges(skillID: fixture.skill.id)
        await windowLoaded(review.window)
        let state = review.window.state
        review.routing.window.onUpdate()
        await review.sheet.loadAndReport(context: context)
        let row = try XCTUnwrap(review.sheet.rows.first)
        await review.sheet.applySelectedAndReport(context: context)
        guard case let .failed(message, _) = review.sheet.status(for: row) else {
            return XCTFail("A replacement failure must remain on the sheet's row")
        }
        XCTAssertTrue(message.contains(CrashManifest.InjectedFailure().localizedDescription))
        XCTAssertTrue(review.library.readBody(fixture.skill).contains("next body"), "The replacement really happened")
        review.window.validate(skills: [fixture.skill], folderRevisions: review.library.folderChangeRevisions, context: context)
        XCTAssertEqual(review.window.state, state, "A replacement failure is a sheet result, never a window result")
    }

    private struct HandoffReview {
        let routing: UpdateReviewRouting
        let sheet: UpdatesViewModel
        let window: ViewChangesViewModel
        let library: SkillLibraryViewModel
    }

    private func makeRealHandoff(fixture: RealFixture, service: SkillInstallService? = nil) -> HandoffReview {
        let (operations, library) = makeRealReviewOperations(fixture: fixture, service: service)
        let sheet = UpdatesViewModel(rowLoader: operations.rowLoader, applyOperation: operations.applyOperation,
                                    recheckOperation: operations.recheckOperation,
                                    bodyWriteRegistration: SyncBodyWriteRegistration(
                                        begin: library.beginAppAuthoredBodyWrite,
                                        end: { library.finishAppAuthoredBodyWrite(directoryName: $0, succeeded: $1) }
                                    ))
        let window = ViewChangesViewModel(library: library, operations: UpdateReviewOperations(
            diffOperation: operations.diffOperation,
            recheckOperation: operations.recheckOperation))
        let routing = UpdateReviewRouting(preview: window, updates: sheet, library: library,
                                         context: context, windows: { [] }, openWindow: { _ in })
        return HandoffReview(routing: routing, sheet: sheet, window: window, library: library)
    }
}
