import SwiftData
import XCTest
@testable import Pensieve

extension UpdatesViewModelTests {
    func testBrokenUnrelatedSkillDoesNotFailPinnedPreview() async throws {
        let fixture = try prepareRealPinnedUpdate()
        let broken = Skill(name: "Broken", directoryName: "missing-folder")
        broken.installedOrigin = fixture.skill.installedOrigin
        broken.updateAvailable = true
        broken.upstreamCommit = fixture.skill.upstreamCommit
        broken.upstreamTree = fixture.skill.upstreamTree
        broken.upstreamCommitDate = fixture.skill.upstreamCommitDate
        context.insert(broken)
        try context.save()
        let (window, _) = makeRealWindow(fixture: fixture)
        window.open(skillID: fixture.skill.id, context: context)
        await windowLoaded(window)
        XCTAssertTrue(window.canUpdate, "An unrelated broken folder must never enter this preview's drift check")
    }

    func testSheetFailureAfterReplacementInvalidatesTheEditorBody() async throws {
        let fixture = try prepareRealPinnedUpdate()
        let failingManifest = CrashManifest(wrapped: ManifestService(fileService: fileService), failurePoint: .beforeUpsert)
        let service = SkillInstallService(
            gitService: GitService(fileService: fileService), credentialStore: InMemoryCredentialStore(),
            fileService: fileService, scratchRoot: tempDir + "/sheet-failure", storeRoot: fixture.storeRoot,
            manifestService: failingManifest, lockPath: tempDir + "/sync.lock",
            remoteValidator: { ValidatedInstallRemote(repo: $0, cloneRemote: $0) }
        )
        let (operations, library) = makeRealReviewOperations(fixture: fixture, service: service)
        let row = try UpdatesViewModel.makeRow(skill: fixture.skill, driftedLocally: false)
        let sheet = UpdatesViewModel(rowLoader: operations.rowLoader, applyOperation: operations.applyOperation,
                                    diffOperation: operations.diffOperation, recheckOperation: operations.recheckOperation,
                                    bodyWriteRegistration: operations.bodyWriteRegistration)
        let routing = UpdateReviewRouting(
            preview: ViewChangesViewModel(operations: operations, applyGate: sheet.applyGate), updates: sheet,
                                          library: library, context: context, openWindow: { _ in })
        routing.presentUpdates(skillID: fixture.skill.id)
        await sheet.loadAndReport(context: context)
        let before = library.reloadToken
        await sheet.applySelectedAndReport(context: context)
        guard case .failedAfterReplacement = sheet.status(for: row) else { return XCTFail("Expected post-write failure") }
        XCTAssertTrue(library.readBody(fixture.skill).contains("fresh body"), "Replacement actually happened")
        XCTAssertGreaterThan(library.reloadToken, before, "The sheet must invalidate Detail's body after replacement failure")
    }
}
