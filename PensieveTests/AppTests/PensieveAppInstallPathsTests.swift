import XCTest
@testable import Pensieve

@MainActor
final class PensieveAppInstallPathsTests: XCTestCase {
    func testInstallSheetUsesRuntimePathsAndMemoryCredentials() throws {
        let paths = try AppRuntimePaths.temporary(named: "PensieveAppInstallPathsTests")
        let temporaryRoot = (paths.storeRoot as NSString).deletingLastPathComponent
        defer { try? FileService().deleteDirectory(at: temporaryRoot) }
        let runtime = try AppRuntime(
            paths: paths,
            gitUsabilityProbe: { .usable }
        )
        let view = PensieveApp.makeContentView(runtime: runtime)
        let service = try XCTUnwrap(view.installVM.service as? SkillInstallService)

        XCTAssertEqual(service.storeRoot, paths.storeRoot)
        XCTAssertEqual(service.scratchRoot, paths.appSupportDir + "/skill-install-scratch")
        XCTAssertEqual(service.lockPath, paths.syncLockPath)
        XCTAssertTrue(service.credentialStore is InMemoryCredentialStore)
    }
}
