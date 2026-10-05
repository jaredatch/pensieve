import SwiftData
import XCTest
@testable import Pensieve

extension UpdatesViewModelTests {
    func testWindowAppliesRealPinnedUpdateClosesAndSettlesCleanRetainedDraft() async throws {
        let fixture = try prepareRealPinnedUpdate()
        let (window, library) = makeRealWindow(fixture: fixture)
        let oldBody = library.readBody(fixture.skill)
        library.setLastWrittenBody("older baseline", directoryName: fixture.skill.directoryName)
        library.noteEditorChanged(fixture.skill, body: oldBody)
        library.setLastWrittenBody(oldBody, directoryName: fixture.skill.directoryName)
        XCTAssertNotNil(library.drafts[fixture.skill.directoryName])
        XCTAssertFalse(library.hasUnsavedChanges)
        window.open(skillID: fixture.skill.id, context: context)
        await windowLoaded(window)
        var closed = 0
        window.requestUpdate(library: library, context: context, onSuccess: { closed += 1 })
        await TestWait.until(failureMessage: "window update did not finish") { !window.isApplying }
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(window.state, .idle)
        XCTAssertEqual(fixture.skill.installedOrigin?.installedCommit, fixture.pinnedCommit)
        XCTAssertFalse(fixture.skill.updateAvailable)
        XCTAssertEqual(fixture.skill.name, "Fresh Name")
        XCTAssertTrue(library.readBody(fixture.skill).contains("fresh body"))
        XCTAssertNil(library.drafts[fixture.skill.directoryName])
        XCTAssertTrue(library.saveDraft(fixture.skill))
        XCTAssertTrue(library.readBody(fixture.skill).contains("fresh body"), "Save cannot reapply the old retained text")
    }

    func testWindowBusyLockRefusalKeepsPreviewOpenAndRealFilesUnchanged() async throws {
        let fixture = try prepareRealPinnedUpdate()
        let (window, library) = makeRealWindow(fixture: fixture)
        window.open(skillID: fixture.skill.id, context: context)
        await windowLoaded(window)
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: tempDir + "/sync.lock"))
        defer { lock.release() }
        try await assertWindowRefusal(window, fixture: fixture, library: library,
                                      message: SkillInstallError.syncInProgress.localizedDescription)
    }

    func testWindowMovedPinRefusalKeepsPreviewOpenAndRealFilesUnchanged() async throws {
        let fixture = try prepareRealPinnedUpdate()
        let (window, library) = makeRealWindow(fixture: fixture)
        window.open(skillID: fixture.skill.id, context: context)
        await windowLoaded(window)
        try fileService.writeFile(at: fixture.repository + "/README.md", content: "move repository head\n")
        _ = try commit(fixture.repository, message: "head moved after preview")
        try await assertWindowRefusal(window, fixture: fixture, library: library,
                                      message: SkillUpdateFlowError.repositoryChangedMessage)
    }

    func testWindowApplyTimeDriftRefusesBeforeWritingAndOffersExplicitReplacement() async throws {
        let fixture = try prepareRealPinnedUpdate()
        let (window, library) = makeRealWindow(fixture: fixture)
        window.open(skillID: fixture.skill.id, context: context)
        await windowLoaded(window)
        let path = fixture.storeRoot + "/skills/vendor/SKILL.md"
        try fileService.writeFile(at: path, content: "---\nname: Mine\ndescription: My edits\n---\nkeep my local edits\n")
        let before = try fileService.readData(at: path)
        var closed = false
        window.requestUpdate(library: library, context: context, onSuccess: { closed = true })
        await TestWait.until(failureMessage: "drift refusal did not finish") { !window.isApplying }
        XCTAssertFalse(closed)
        XCTAssertTrue(window.row?.driftedLocally == true)
        XCTAssertTrue(window.applyMessage?.contains("local edits") == true)
        XCTAssertEqual(try fileService.readData(at: path), before)
        XCTAssertTrue(window.canUpdate)
        window.requestUpdate(library: library, context: context, onSuccess: { closed = true })
        XCTAssertTrue(window.asksToReplaceLocalEdits)
        window.confirmReplacement(false, library: library, context: context, onSuccess: { closed = true })
        XCTAssertEqual(try fileService.readData(at: path), before)
        XCTAssertFalse(closed)
    }

    func testWindowManifestFailureAfterReplacementNamesChangedFilesAndRefreshesDiskBody() async throws {
        let fixture = try prepareRealPinnedUpdate()
        let failingManifest = CrashManifest(wrapped: ManifestService(fileService: fileService), failurePoint: .beforeUpsert)
        let service = SkillInstallService(
            gitService: GitService(fileService: fileService), credentialStore: InMemoryCredentialStore(),
            fileService: fileService, scratchRoot: tempDir + "/failing-scratch", storeRoot: fixture.storeRoot,
            manifestService: failingManifest, lockPath: tempDir + "/sync.lock",
            remoteValidator: { ValidatedInstallRemote(repo: $0, cloneRemote: $0) }
        )
        let (window, library) = makeRealWindow(fixture: fixture, service: service)
        library.setLastWrittenBody(library.readBody(fixture.skill), directoryName: fixture.skill.directoryName)
        window.open(skillID: fixture.skill.id, context: context)
        await windowLoaded(window)
        let revision = library.reloadToken
        var closed = false
        window.requestUpdate(library: library, context: context, onSuccess: { closed = true })
        await TestWait.until(failureMessage: "post-replacement failure did not finish") { !window.isApplying }
        XCTAssertFalse(closed)
        guard case let .stale(message) = window.state else { return XCTFail("Expected explicit post-write state") }
        XCTAssertTrue(message.contains("files were replaced"))
        XCTAssertTrue(message.contains(CrashManifest.InjectedFailure().localizedDescription))
        XCTAssertFalse(window.canUpdate)
        XCTAssertNil(window.selectedFile)
        XCTAssertTrue(library.readBody(fixture.skill).contains("fresh body"))
        XCTAssertGreaterThan(library.reloadToken, revision, "Detail reloads after a post-write failure")
        XCTAssertTrue(library.wasLastWrittenByApp(directoryName: fixture.skill.directoryName,
                                                currentBody: library.readBody(fixture.skill)))
    }

    private func makeRealWindow(
        fixture: RealFixture, service: SkillInstallService? = nil
    ) -> (ViewChangesViewModel, SkillLibraryViewModel) {
        let library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: fileService, baseDir: fixture.storeRoot + "/skills"), fileService: fileService,
            fileWatchService: FileWatchService(rootDir: fixture.storeRoot + "/skills"), manifestRoot: fixture.storeRoot
        )
        let installer = service ?? fixture.service
        let checker = UpdateCheckService(
            credentialStore: InMemoryCredentialStore(), fileService: fileService, contentHasher: installer,
            scratchRoot: tempDir + "/check-scratch", storeRoot: fixture.storeRoot,
            remoteValidator: { ValidatedInstallRemote(repo: $0, cloneRemote: $0) }
        )
        let defaults = UpdatesViewModel.DefaultOperations(updateCheckService: checker, skillInstallService: installer)
        let model = UpdatesViewModel(
            rowLoader: defaults.rowLoader, applyOperation: defaults.applyOperation,
            diffOperation: defaults.diffOperation, recheckOperation: defaults.recheckOperation,
            bodyWriteRegistration: SyncBodyWriteRegistration(
                begin: library.beginAppAuthoredBodyWrite,
                end: { library.finishAppAuthoredBodyWrite(directoryName: $0, succeeded: $1) }
            )
        )
        return (ViewChangesViewModel(operations: model), library)
    }

    private func windowLoaded(_ model: ViewChangesViewModel) async {
        await TestWait.until(failureMessage: "real window preview did not finish") { model.state != .loading }
        XCTAssertNotNil(model.selectedFile)
    }

    private func assertWindowRefusal(_ window: ViewChangesViewModel, fixture: RealFixture,
                                     library: SkillLibraryViewModel, message: String) async throws {
        let path = fixture.storeRoot + "/skills/vendor/SKILL.md"
        let before = try fileService.readData(at: path)
        var closed = false
        window.requestUpdate(library: library, context: context, onSuccess: { closed = true })
        await TestWait.until(failureMessage: "window refusal did not finish") { !window.isApplying }
        XCTAssertFalse(closed)
        XCTAssertEqual(window.applyMessage, message)
        XCTAssertNotNil(window.selectedFile)
        XCTAssertTrue(window.canUpdate)
        XCTAssertEqual(try fileService.readData(at: path), before)
        XCTAssertTrue(fixture.skill.updateAvailable)
        XCTAssertEqual(fixture.skill.upstreamCommit, fixture.pinnedCommit)
    }
}
