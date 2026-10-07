import SwiftData
import XCTest
@testable import Pensieve

extension SyncEngineTests {
    @MainActor
    func testOutputReadFailureDuringSyncRemainsALocalFailure() async throws {
        let failure = GitError.outputReadFailed(detail: "Authentication failed; CONFLICT; Xcode license not accepted")
        let message = "Pensieve couldn’t read git’s output: Authentication failed; CONFLICT; Xcode license not accepted"
        let git = StubGit()
        git.pullError = failure
        let engine = makeEngine(git: git)
        let context = try makeContext()
        XCTAssertThrowsError(try engine.sync(root: tempDir, message: "test", credential: nil, context: context)) {
            XCTAssertEqual($0 as? GitError, failure)
            XCTAssertEqual($0.localizedDescription, message)
        }
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let coordinator = SyncCoordinator(modelContainer: container)
        await coordinator.configure(engine: engine, git: git, credentials: InMemoryCredentialStore(), root: tempDir,
                                    audit: SyncAudit(appSupport: tempDir + "/support"),
                                    machineIdentity: InertMachineIdentity(), machineStateService: InertMachineStateService())
        let outcome = await coordinator.runCycle()
        XCTAssertEqual(outcome, .failed(message))
        XCTAssertFalse(git.calls.contains("push"))
    }

}
