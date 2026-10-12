import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class SyncTokenModelTests: XCTestCase {
    func testAcceptedReplacementReachesNextSyncAndRefusalKeepsOldToken() async throws {
        let fixture = try NativeTestWork.run { try GitCredentialFixture() }
        defer { try? fixture.remove() }
        let root = fixture.base + "/store"
        let lockPath = fixture.base + "/sync.lock"
        try seed(fixture, root: root)
        let credentials = InMemoryCredentialStore()
        let old = GitCredential.httpsToken(username: "kept-username", token: "expired-token")
        try credentials.store(token: "expired-token", username: "kept-username", forHost: "fixture.test")
        try credentials.store(token: "install-token", username: "install", forHost: "fixture.test#install")
        let model = SyncTokenModel(git: fixture.git, credentials: credentials,
            root: root, lockPath: lockPath, steps: SyncStepModel())
        model.refresh(remoteURL: fixture.remote)
        XCTAssertTrue(model.hasSavedToken)
        for token in ["", " \t\n"] {
            model.token = token
            XCTAssertFalse(model.canSave)
            model.save()
            XCTAssertEqual(model.state, .idle)
        }
        try fixture.clearTraces()
        let config = try fixture.files.readData(at: root + "/.git/config")
        model.token = "refused-token"
        model.save()
        await finished(model)
        XCTAssertEqual(model.state, .failed("fixture.test didn’t accept this token. Your saved token hasn’t changed."))
        XCTAssertEqual(credentials.credential(forHost: "fixture.test"), old)
        XCTAssertEqual(try fixture.files.readData(at: root + "/.git/config"), config)
        model.token = fixture.token
        model.save()
        await finished(model)
        XCTAssertEqual(model.state, .saved)
        XCTAssertEqual(model.token, "")
        XCTAssertEqual(credentials.credential(forHost: "fixture.test"),
            .httpsToken(username: "kept-username", token: fixture.token))
        XCTAssertEqual(credentials.credential(forHost: "fixture.test#install"),
            .httpsToken(username: "install", token: "install-token"))
        let checkCalls = try fixture.files.readFile(at: fixture.networkTrace).split(separator: "\n")
        XCTAssertEqual(checkCalls, ["ls-remote"], "Replacement checks must not fetch or push")
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let coordinator = SyncCoordinator(modelContainer: container)
        await coordinator.configure(engine: SyncEngine(gitService: fixture.git, lockPath: lockPath),
            git: fixture.git, credentials: credentials, root: root, audit: SyncAudit(appSupport: fixture.base + "/audit"),
            machine: (InertMachineIdentity(), InertMachineStateService()))
        guard case .synced = await coordinator.runCycle() else { return XCTFail("Next sync must use the replacement") }
        let calls = try fixture.files.readFile(at: fixture.networkTrace)
        XCTAssertTrue(calls.contains("fetch"))
        XCTAssertTrue(calls.contains("push"))
        XCTAssertEqual(try fixture.files.readFile(at: fixture.foreignTrace), "")
        XCTAssertFalse(try fixture.files.readFile(at: fixture.argvTrace).contains(fixture.token))
    }

    func testCancelledRemoteCheckAndNetworkFailureKeepStoredToken() async throws {
        let fixture = try GitFailureFixture()
        let block = try GitBlockingFixture()
        defer { try? fixture.remove(); try? block.cleanup() }
        try fixture.seedRepository()
        let git = try fixture.executable("""
            check() {
                \(FakeGitScript.skipGlobalOptions)
                if [ "$1" = ls-remote ]; then exec '\(block.root)/git' "$@"; fi
            }
            check "$@"
            exec /usr/bin/git "$@"
            """)
        let credentials = InMemoryCredentialStore()
        try credentials.store(token: "old", username: "kept", forHost: "fixture.test")
        let model = SyncTokenModel(git: git, credentials: credentials,
            root: fixture.root, lockPath: fixture.support + "/sync.lock", steps: SyncStepModel())
        model.refresh(remoteURL: "https://fixture.test/store.git")
        model.token = "new"
        model.save()
        await TestWait.until(failureMessage: "Token check did not reach the held remote read") { block.isBlocked }
        XCTAssertTrue(model.canCancel)
        XCTAssertFalse(model.canSave)
        try NativeTestWork.run { try git.removeRemote(at: fixture.root) }
        model.refresh(remoteURL: nil)
        model.cancel()
        await finished(model)
        XCTAssertEqual(model.state, .cancelled)
        XCTAssertNil(model.remote, "A refresh during checking must retire the disconnected token control")
        XCTAssertFalse(model.hasSavedToken)
        XCTAssertFalse(block.isBlocked, "Cancel must terminate the read-only git check")
        XCTAssertEqual(credentials.credential(forHost: "fixture.test"), .httpsToken(username: "kept", token: "old"))
        try NativeTestWork.run { try git.setRemote("https://fixture.test/store.git", at: fixture.root) }
        model.refresh(remoteURL: "https://fixture.test/store.git")
        try installNetworkFailure(fixture)
        model.token = "new"
        model.save()
        await finished(model)
        XCTAssertEqual(model.state, .failed("Couldn’t reach fixture.test. Your saved token hasn’t changed."))
        XCTAssertEqual(credentials.credential(forHost: "fixture.test"), .httpsToken(username: "kept", token: "old"))
    }

    func testAddAfterSyncLockReleaseAndChangedRemoteRefusal() async throws {
        let fixture = try NativeTestWork.run { try GitCredentialFixture() }
        defer { try? fixture.remove() }
        let root = fixture.base + "/store", lockPath = fixture.base + "/sync.lock"
        try NativeTestWork.run {
            try fixture.files.createDirectory(at: root)
            try fixture.git.initRepository(at: root)
            try fixture.git.setRemote(fixture.remote, at: root)
        }
        let credentials = InMemoryCredentialStore()
        let model = SyncTokenModel(git: fixture.git, credentials: credentials,
            root: root, lockPath: lockPath, steps: SyncStepModel())
        model.refresh(remoteURL: fixture.remote)
        XCTAssertFalse(model.hasSavedToken)
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
        defer { held.release() }
        model.token = fixture.token
        model.save()
        XCTAssertEqual(model.state, .checking)
        held.release()
        await finished(model)
        XCTAssertEqual(model.state, .saved)
        XCTAssertEqual(credentials.credential(forHost: "fixture.test"),
            .httpsToken(username: "x-access-token", token: fixture.token))
        try NativeTestWork.run { try fixture.git.setRemote("https://other.test/store.git", at: root) }
        model.token = "another"
        model.save()
        await finished(model)
        XCTAssertEqual(model.state, .failed("The sync repository changed. Close this sheet and try again."))
        XCTAssertNil(credentials.credential(forHost: "other.test"))
        XCTAssertEqual(credentials.credential(forHost: "fixture.test"),
            .httpsToken(username: "x-access-token", token: fixture.token))
    }

    private func seed(_ fixture: GitCredentialFixture, root: String) throws {
        try NativeTestWork.run {
            try fixture.files.createDirectory(at: root)
            try fixture.git.initRepository(at: root)
            try fixture.git.setRemote(fixture.remote, at: root)
            try fixture.files.writeFile(at: root + "/skills/example/SKILL.md",
                content: "---\nname: Example\ndescription: Test\n---\nBody\n")
            try ManifestService().write(.init(schemaVersion: ManifestService.currentSchemaVersion,
                categories: [], projects: [], skills: []), toRoot: root)
            _ = try fixture.git.stageAllAndCommit(at: root, message: "Seed")
            try fixture.git.push(at: root, credential: fixture.credential)
        }
    }

    private func finished(_ model: SyncTokenModel) async {
        await TestWait.until(failureMessage: "Token replacement did not finish") { model.state != .checking }
    }

    private func installNetworkFailure(_ fixture: GitFailureFixture) throws {
        _ = try fixture.executable("""
            check() {
                \(FakeGitScript.skipGlobalOptions)
                if [ "$1" = ls-remote ]; then echo 'Could not resolve host' >&2; exit 128; fi
            }
            check "$@"
            exec /usr/bin/git "$@"
            """)
    }
}
