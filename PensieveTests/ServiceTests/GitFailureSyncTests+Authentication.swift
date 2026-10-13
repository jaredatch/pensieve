import SwiftData
import XCTest
@testable import Pensieve

extension GitFailureSyncTests {
    func testSyncAndConflictAdviceNamesTokenRepairOrSSHAgent() async throws {
        let cases: [AdviceCase] = [
            .init(remote: "https://fixture.test/store.git", token: nil, advice:
             "Sync over HTTPS needs an access token. Add one in Settings › Sync."),
            .init(remote: "https://fixture.test/store.git", token: " \t\n", advice:
             "Sync over HTTPS needs an access token. Add one in Settings › Sync."),
            .init(remote: "https://fixture.test/store.git", token: "expired", advice:
             "fixture.test didn’t accept the access token. Replace it in Settings › Sync."),
            .init(remote: "git@example.com:store.git", token: nil, advice:
             "Couldn’t authenticate to example.com over SSH. Add your key to the agent "
                + "(run ssh-add in Terminal), then sync again."),
            .init(remote: "git@example.com:store.git", token: nil, advice:
             "Connect to example.com once with ssh in Terminal to check and accept its key, then sync again.",
             detail: "Host key verification failed")
        ]
        for entry in cases {
            let remote = entry.remote, token = entry.token, advice = entry.advice
            let fixture = try GitFailureFixture()
            defer { try? fixture.remove() }
            try fixture.seedRepository(remote: remote)
            let credentials = InMemoryCredentialStore()
            if let token { try credentials.store(token: token, username: "kept", forHost: "fixture.test") }
            let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
            let engine = AuthenticationAdviceEngine()
            engine.detail = entry.detail
            let coordinator = SyncCoordinator(modelContainer: container)
            await coordinator.configure(engine: engine, git: fixture.paths.makeGitService(), credentials: credentials,
                root: fixture.root, audit: SyncAudit(appSupport: fixture.support),
                machine: (InertMachineIdentity(), InertMachineStateService()))
            let result = await coordinator.runCycle()
            XCTAssertEqual(result, .failed(advice))
            let sync = SyncModel(git: fixture.paths.makeGitService(), root: fixture.root)
            sync.apply(result)
            XCTAssertEqual(sync.state, .error(advice), "Chrome must retain the repair advice")
            let conflicts = ConflictResolutionModel(engine: engine, git: fixture.paths.makeGitService(),
                credentials: credentials, root: fixture.root, steps: SyncStepModel())
            await conflicts.loadAndReport(container: container)
            guard case let .ready(groups) = conflicts.phase, let group = groups.first else {
                return XCTFail("Expected one conflict before the refused push")
            }
            conflicts.choose(group.id, .thisMachine)
            await conflicts.applyAndReport(container: container)
            let expected = remote.hasPrefix("https")
                ? String(advice.dropLast()) + ", then try again." : advice
            XCTAssertEqual(conflicts.phase, .error(expected))
            engine.failInspection = true
            await conflicts.loadAndReport(container: container)
            XCTAssertEqual(conflicts.phase, .error(expected), "Conflict inspection needs the same repair path")
        }
    }

}

private struct AdviceCase {
    let remote: String
    let token: String?
    let advice: String
    var detail = "refused"
}

private final class AuthenticationAdviceEngine: SyncEngineProtocol {
    var failInspection = false
    var detail = "refused"
    private var failure: GitError { .authenticationFailed(remote: "origin", detail: detail) }
    func sync(root: String, message: String, credential: GitCredential?, context: ModelContext,
              prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome { throw failure }
    func inspectConflicts(root: String, credential: GitCredential?, context: ModelContext) throws -> ConflictInspection {
        if failInspection { throw failure }
        return .conflicts(ConflictSet(items: [ConflictItem(path: "skills/example/SKILL.md", kind: .body,
            thisMachine: Data("local".utf8), otherMachine: Data("remote".utf8))]))
    }
    func resolveConflicts(root: String, picks: [String: ResolutionPick], credential: GitCredential?,
                          context: ModelContext) throws -> SyncOutcome { throw failure }
}
