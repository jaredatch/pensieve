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
        let old = GitCredential.httpsToken(username: "kept-username", token: "expired-token", host: "fixture.test")
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
            .httpsToken(username: "kept-username", token: fixture.token, host: "fixture.test"))
        XCTAssertEqual(credentials.credential(forHost: "fixture.test#install"),
            .httpsToken(username: "install", token: "install-token", host: "fixture.test"))
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
        await TestWait.until(failureMessage: "Cancel must terminate the read-only git check") { !block.isBlocked }
        XCTAssertFalse(block.isBlocked, "Cancel must terminate the read-only git check")
        XCTAssertEqual(credentials.credential(forHost: "fixture.test"),
            .httpsToken(username: "kept", token: "old", host: "fixture.test"))
        try NativeTestWork.run { try git.setRemote("https://fixture.test/store.git", at: fixture.root) }
        model.refresh(remoteURL: "https://fixture.test/store.git")
        try await assertFailedChecksKeepStoredToken(fixture, git: git, model: model, credentials: credentials)
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
            .httpsToken(username: "x-access-token", token: fixture.token, host: "fixture.test"))
        try NativeTestWork.run { try fixture.git.setRemote("https://other.test/store.git", at: root) }
        model.token = "another"
        model.save()
        await finished(model)
        XCTAssertEqual(model.state, .failed("The sync repository changed. Close this sheet and try again."))
        XCTAssertNil(credentials.credential(forHost: "other.test"))
        XCTAssertEqual(credentials.credential(forHost: "fixture.test"),
            .httpsToken(username: "x-access-token", token: fixture.token, host: "fixture.test"))
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

}

extension SyncTokenModelTests {
    func testCancelWhileWaitingForSyncLockAllowsFreshCheck() async throws {
        let fixture = try NativeTestWork.run { try GitCredentialFixture() }
        defer { try? fixture.remove() }
        let root = fixture.base + "/store", lockPath = fixture.base + "/sync.lock"
        try seed(fixture, root: root)
        let credentials = InMemoryCredentialStore()
        try credentials.store(token: "old", username: "kept", forHost: "fixture.test")
        let model = SyncTokenModel(git: fixture.git, credentials: credentials,
            root: root, lockPath: lockPath, steps: SyncStepModel())
        model.refresh(remoteURL: fixture.remote)
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
        defer { held.release() }
        try fixture.clearTraces()
        model.token = "cancelled-token"
        model.save()
        // Let the native worker enter the contended wait without releasing the holder.
        try await Task.sleep(for: .milliseconds(100))
        model.cancel()
        XCTAssertEqual(model.state, .cancelled)
        model.prepareForPresentation()
        XCTAssertEqual(model.state, .idle, "Reopening must offer an editable token field immediately")
        guard model.state == .idle else { return }
        model.refresh(remoteURL: fixture.remote)
        XCTAssertTrue(model.hasSavedToken)
        XCTAssertEqual(credentials.credential(forHost: "fixture.test"),
            .httpsToken(username: "kept", token: "old", host: "fixture.test"))
        model.token = fixture.token
        model.save()
        XCTAssertEqual(model.state, .checking)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.state, .checking, "An old completion must not clear the newer check")
        XCTAssertEqual(model.token, fixture.token)
        held.release()
        await finished(model)
        XCTAssertEqual(model.state, .saved, "The cancelled worker must not overwrite the newer check")
        XCTAssertEqual(credentials.credential(forHost: "fixture.test"),
                       .httpsToken(username: "kept", token: fixture.token, host: "fixture.test"))
        XCTAssertEqual(try fixture.files.readFile(at: fixture.networkTrace).split(separator: "\n"), ["ls-remote"])
    }

    func testSuccessfulReplacementRetriesSyncWithBackgroundSyncOffExceptDuringConflict() async throws {
        for conflicted in [false, true] {
            let fixture = try NativeTestWork.run { try GitCredentialFixture() }
            defer { try? fixture.remove() }
            let root = fixture.base + "/store", lockPath = fixture.base + "/sync.lock"
            try seed(fixture, root: root)
            let paths = AppRuntimePaths(storeRoot: root, appSupportDir: fixture.base + "/support")
            let credentials = paths.makeCredentialStore()
            try credentials.store(token: "expired", username: "kept", forHost: "fixture.test")
            let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
            let setup = SyncSetupModel(context: container.mainContext, git: fixture.git, credentials: credentials,
                root: root, lockPath: lockPath, steps: SyncStepModel())
            let sync = SyncModel(git: fixture.git, root: root,
                initialState: conflicted ? .conflicted(["skills/example/SKILL.md"]) : .error("refused token"))
            let runtime = try AppRuntime(container: container, syncModel: sync, syncSetup: setup,
                scheduler: SyncScheduler(startAutomatically: false), launchBackfill: { _ in }, paths: paths,
                coordinatorConfigure: { coordinator in
                    await coordinator.configure(engine: SyncEngine(gitService: fixture.git, lockPath: lockPath),
                        git: fixture.git, credentials: credentials, root: root,
                        audit: SyncAudit(appSupport: paths.appSupportDir),
                        machine: (InertMachineIdentity(), InertMachineStateService()))
                })
            await runtime.bootstrapTask.value
            runtime.backgroundSyncEnabled = false
            try fixture.clearTraces()
            setup.syncToken.refresh(remoteURL: fixture.remote)
            setup.syncToken.token = fixture.token
            setup.syncToken.save()
            await finished(setup.syncToken)
            XCTAssertEqual(setup.syncToken.state, .saved)
            if conflicted {
                XCTAssertTrue(sync.isConflicted)
                XCTAssertEqual(try fixture.files.readFile(at: fixture.networkTrace).split(separator: "\n"), ["ls-remote"])
            } else {
                await TestWait.until(failureMessage: "Replacing a token must retry Sync Now with background sync off") {
                    if case .synced = sync.state { return true }
                    return false
                }
                let calls = try fixture.files.readFile(at: fixture.networkTrace)
                XCTAssertTrue(calls.contains("fetch"))
                XCTAssertTrue(calls.contains("push"))
            }
        }
    }

    private func finished(_ model: SyncTokenModel) async {
        await TestWait.until(failureMessage: "Token replacement did not finish") { model.state != .checking }
    }

    private func assertFailedChecksKeepStoredToken(_ fixture: GitFailureFixture, git: GitService,
                                                   model: SyncTokenModel, credentials: InMemoryCredentialStore) async throws {
        let refused = "This token can’t open the sync repository on fixture.test. Your saved token hasn’t changed."
        let cases: [(detail: String, advice: String?)] = [
            ("Could not resolve host", "Couldn’t reach fixture.test. Your saved token hasn’t changed."),
            ("Could not resolve proxy", "Couldn’t reach fixture.test. Your saved token hasn’t changed."),
            ("Connection reset by peer", "Couldn’t reach fixture.test. Your saved token hasn’t changed."),
            ("Empty reply from server", "Couldn’t reach fixture.test. Your saved token hasn’t changed."),
            ("The requested URL returned error: 403",
             "fixture.test didn’t accept this token. Your saved token hasn’t changed."),
            ("remote: Repository not found.", refused),
            ("fatal: unable to access repository: The requested URL returned error: 404", refused),
            ("fatal: invalid ref advertisement", nil)
        ]
        let config = try fixture.files.readData(at: fixture.root + "/.git/config")
        for entry in cases {
            try installCheckFailure(fixture, detail: entry.detail)
            model.token = "new"
            model.save()
            await finished(model)
            if let advice = entry.advice {
                XCTAssertEqual(model.state, .failed(advice), entry.detail)
            } else if case let .failed(message) = model.state {
                XCTAssertTrue(message.contains(entry.detail), "Unclassified git errors must retain their own detail")
                XCTAssertFalse(message.contains("Couldn’t reach"))
            } else { XCTFail("Expected the remote check to fail") }
            XCTAssertEqual(credentials.credential(forHost: "fixture.test"),
                .httpsToken(username: "kept", token: "old", host: "fixture.test"))
            XCTAssertEqual(try fixture.files.readData(at: fixture.root + "/.git/config"), config)
        }
        let parent = fixture.support + "/not-a-directory"
        try fixture.files.writeFile(at: parent, content: "blocks lock creation")
        let local = SyncTokenModel(git: git, credentials: credentials, root: fixture.root,
            lockPath: parent + "/sync.lock", steps: SyncStepModel())
        local.refresh(remoteURL: "https://fixture.test/store.git")
        local.token = "new"
        local.save()
        await finished(local)
        XCTAssertEqual(local.state, .failed(POSIXError(.ENOTDIR).localizedDescription))
        XCTAssertEqual(credentials.credential(forHost: "fixture.test"),
            .httpsToken(username: "kept", token: "old", host: "fixture.test"))
        XCTAssertEqual(try fixture.files.readData(at: fixture.root + "/.git/config"), config)
    }

    private func installCheckFailure(_ fixture: GitFailureFixture, detail: String) throws {
        _ = try fixture.executable("""
            check() {
                \(FakeGitScript.skipGlobalOptions)
                if [ "$1" = ls-remote ]; then printf '%s\\n' '\(detail)' >&2; exit 128; fi
            }
            check "$@"
            exec /usr/bin/git "$@"
            """)
    }
}
