import SwiftData
import XCTest
@testable import Pensieve

extension UpdatesViewModelTests {
    func testIndependentPreviewSkipsDriftHashAndRejectsChangedInstalledPin() async throws {
        let fixture = try prepareRealPinnedUpdate()
        let (_, library) = makeRealReviewOperations(fixture: fixture)
        let hashes = UpdateReviewRecorder<Bool>()
        let checker = UpdateCheckService(credentialStore: InMemoryCredentialStore(), fileService: fileService,
            contentHasher: PreviewHashFailure(calls: hashes), scratchRoot: tempDir + "/unused-drift",
            storeRoot: fixture.storeRoot)
        let defaults = UpdatesViewModel.DefaultOperations(updateCheckService: checker, skillInstallService: fixture.service)
        let window = ViewChangesViewModel(library: library, operations: UpdateReviewOperations(
            diffOperation: defaults.diffOperation,
            recheckOperation: defaults.recheckOperation))
        window.open(skillID: fixture.skill.id, context: context)
        await TestWait.until(failureMessage: "preview without drift hash did not finish") { window.state != .loading }
        XCTAssertNotNil(window.selectedFile, "An unused drift hash failure must not replace the actual diff")
        XCTAssertTrue(hashes.values.isEmpty, "Independent preview must not hash the local folder for drift")
        let origin = try XCTUnwrap(fixture.skill.installedOrigin)
        // Closing requests a new worker; reopening the same loaded identity now retains its preview.
        window.close()
        window.open(skillID: fixture.skill.id, context: context)
        var moved = origin
        moved.installedCommit = String(repeating: "a", count: 40)
        fixture.skill.installedOrigin = moved
        try context.save()
        await TestWait.until(failureMessage: "changed installed pin did not finish") { window.state != .loading }
        XCTAssertEqual(window.state, .failed(SkillUpdateFlowError.repositoryChanged.localizedDescription),
                       "The worker must verify the installed commit as well as the upstream pin")
        XCTAssertNil(window.selectedFile)
    }

    private struct PreviewHashFailure: SkillContentHashing {
        let calls: UpdateReviewRecorder<Bool>
        func stableContentHash(at directory: String, excludingTopLevelGitMetadata: Bool) throws -> String {
            calls.append(true)
            throw FixtureError.expectedFailure
        }
    }
}
