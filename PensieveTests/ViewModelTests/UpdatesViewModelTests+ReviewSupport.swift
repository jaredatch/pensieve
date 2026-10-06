import SwiftData
import XCTest
@testable import Pensieve

extension UpdatesViewModelTests {
    func makeRealWindow(fixture: RealFixture, service: SkillInstallService? = nil)
        -> (ViewChangesViewModel, SkillLibraryViewModel) {
        let (operations, library) = makeRealReviewOperations(fixture: fixture, service: service)
        return (ViewChangesViewModel(library: library, operations: UpdateReviewOperations(
            diffOperation: operations.diffOperation,
            recheckOperation: operations.recheckOperation)), library)
    }

    func makeRealReviewOperations(
        fixture: RealFixture, service: SkillInstallService? = nil
    ) -> (UpdatesViewModel.DefaultOperations, SkillLibraryViewModel) {
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
        return (defaults, library)
    }

    func windowLoaded(_ model: ViewChangesViewModel) async {
        await TestWait.until(failureMessage: "real window preview did not finish") { model.state != .loading }
        XCTAssertNotNil(model.selectedFile)
    }

}
