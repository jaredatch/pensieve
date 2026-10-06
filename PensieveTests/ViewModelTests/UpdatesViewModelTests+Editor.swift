import XCTest
@testable import Pensieve

extension UpdatesViewModelTests {
    func testReplacementFailureInvalidatesEditorAndSaveKeepsReplacedBody() async throws {
        let fixture = try prepareRealPinnedUpdate()
        let service = SkillInstallService(
            gitService: GitService(fileService: fileService), credentialStore: InMemoryCredentialStore(),
            fileService: fileService, scratchRoot: tempDir + "/editor-failure", storeRoot: fixture.storeRoot,
            manifestService: CrashManifest(wrapped: ManifestService(fileService: fileService), failurePoint: .beforeUpsert),
            lockPath: tempDir + "/sync.lock", remoteValidator: { ValidatedInstallRemote(repo: $0, cloneRemote: $0) }
        )
        let (operations, library) = makeRealReviewOperations(fixture: fixture, service: service)
        let sheet = UpdatesViewModel(
            rowLoader: operations.rowLoader, applyOperation: operations.applyOperation,
            recheckOperation: operations.recheckOperation, echoRegistrar: library.noteAppAuthoredBodies,
            bodyWriteRegistration: SyncBodyWriteRegistration(
                begin: library.beginAppAuthoredBodyWrite,
                end: { library.finishAppAuthoredBodyWrite(directoryName: $0, succeeded: $1) }
            )
        )
        let oldBody = library.editorBody(for: fixture.skill)
        // A clean retained draft must settle at the same presentation gate the window hand-off uses.
        library.setLastWrittenBody("older baseline", directoryName: fixture.skill.directoryName)
        library.noteEditorChanged(fixture.skill, body: oldBody)
        library.setLastWrittenBody(oldBody, directoryName: fixture.skill.directoryName)
        XCTAssertNotNil(library.drafts[fixture.skill.directoryName])
        XCTAssertFalse(library.hasUnsavedChanges)
        sheet.present(selecting: fixture.skill.id, library: library)
        XCTAssertNil(library.drafts[fixture.skill.directoryName])
        await sheet.loadAndReport(context: context)
        let row = try XCTUnwrap(sheet.rows.first)
        let reload = library.reloadToken
        await sheet.applySelectedAndReport(context: context)
        guard case let .failed(message, _) = sheet.status(for: row) else { return XCTFail("The manifest write must fail") }
        XCTAssertTrue(message.contains(CrashManifest.InjectedFailure().localizedDescription))
        let replacedBody = library.readBody(fixture.skill)
        XCTAssertTrue(replacedBody.contains("fresh body"), "The failure follows a real file replacement")
        XCTAssertNotEqual(oldBody, replacedBody)
        XCTAssertGreaterThan(library.reloadToken, reload, "A post-replacement failure must invalidate the open editor")
        XCTAssertTrue(library.saveDraft(fixture.skill))
        XCTAssertEqual(library.readBody(fixture.skill), replacedBody, "Save cannot restore the retained old text")
        XCTAssertEqual(library.editorBody(for: fixture.skill), replacedBody, "The editor reload seam returns the disk body")
        let edited = replacedBody + "\nEdited after the failed update\n"
        library.noteEditorChanged(fixture.skill, body: edited)
        XCTAssertTrue(library.saveDraft(fixture.skill))
        XCTAssertEqual(library.readBody(fixture.skill), SkillParser.canonicalBody(edited))
    }
}
