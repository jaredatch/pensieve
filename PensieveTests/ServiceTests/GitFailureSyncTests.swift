import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class GitFailureSyncTests: XCTestCase {
    func testUnusableAppCycleFailsBeforePreparationAndPreservesStore() async throws {
        for state in [GitUsability.licenseNotAccepted, .developerToolsMissing] {
            let fixture = try GitFailureFixture()
            defer { try? fixture.remove() }
            try fixture.seedRepository()
            let before = try fixture.snapshot()
            let git = try fixture.broken(state)
            let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
            let engine = SyncEngine(gitService: git, lockPath: fixture.support + "/sync.lock")
            var prepared = false
            XCTAssertThrowsError(try engine.sync(
                root: fixture.root, message: "test", credential: nil, context: container.mainContext,
                prepare: { _ in prepared = true }
            )) { XCTAssertEqual($0 as? GitError, .unusable(state)) }
            XCTAssertFalse(prepared)
            let coordinator = SyncCoordinator(modelContainer: container)
            await coordinator.configure(engine: engine, git: git, root: fixture.root,
                                        audit: SyncAudit(appSupport: fixture.support))
            let result = await coordinator.runCycle()
            XCTAssertEqual(result, .failed(state.message ?? ""))
            XCTAssertEqual(try fixture.snapshot(), before)
        }
    }

    func testDaemonRunRecordsUnusableFailureAndPreservesStore() throws {
        for state in [GitUsability.licenseNotAccepted, .developerToolsMissing] {
            let fixture = try GitFailureFixture()
            defer { try? fixture.remove() }
            try fixture.seedRepository()
            let before = try fixture.snapshot()
            let git = try fixture.broken(state)
            let result = runDaemon(fixture, git: git)
            XCTAssertEqual(result.exitCode, 1)
            XCTAssertTrue(result.stdout.contains(state.message ?? "missing message"))
            let status = try JSONDecoder().decode(
                DaemonStatus.self, from: fixture.files.readData(at: fixture.support + "/daemon-status.json")
            )
            XCTAssertEqual(status.result, "failed")
            XCTAssertEqual(status.detail, state.message)
            XCTAssertEqual(try fixture.snapshot(), before)
        }
    }

    func testWorkingGitWithoutRemoteStillSkipsWithoutWriting() throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository(remote: nil)
        let before = try fixture.snapshot()
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(lockPath: fixture.support + "/sync.lock")
        var prepared = false
        XCTAssertEqual(try engine.sync(root: fixture.root, message: "test", credential: nil,
                                      context: container.mainContext, prepare: { _ in prepared = true }), .noRemote)
        XCTAssertFalse(prepared)
        XCTAssertEqual(runDaemon(fixture, git: GitService()).exitCode, 0)
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testDamagedRepositoryStopsEngineCoordinatorAndConflictLoad() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        try fixture.files.deleteFile(at: fixture.root + "/.git/HEAD")
        let before = try fixture.snapshot()
        let git = GitService()
        XCTAssertEqual(try git.probeUsability(), .usable)
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(lockPath: fixture.support + "/sync.lock")
        XCTAssertThrowsError(try engine.sync(root: fixture.root, message: "test", credential: nil,
                                             context: container.mainContext)) { assertRepositoryFailure($0, fixture: fixture) }
        let spy = GitFailureEngineSpy()
        let coordinator = SyncCoordinator(modelContainer: container)
        await coordinator.configure(engine: spy, git: git, root: fixture.root,
                                    audit: SyncAudit(appSupport: fixture.support))
        guard case let .failed(message) = await coordinator.runCycle() else { return XCTFail("must fail") }
        XCTAssertTrue(message.contains("repository"))
        XCTAssertTrue(message.contains(fixture.root))
        let model = ConflictResolutionModel(engine: spy, git: git, root: fixture.root)
        await model.loadAndReport(context: container.mainContext)
        guard case let .error(detail) = model.phase else { return XCTFail("must fail before inspection") }
        XCTAssertTrue(detail.contains("repository"))
        XCTAssertEqual(spy.calls, 0, "unknown must never become a call without credentials")
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testDamagedRepositoryDaemonAndConnectRefuseMutation() throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        try fixture.files.deleteFile(at: fixture.root + "/.git/HEAD")
        let before = try fixture.snapshot()
        let result = runDaemon(fixture, git: GitService())
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stdout.contains("repository"))
        let status = try JSONDecoder().decode(
            DaemonStatus.self, from: fixture.files.readData(at: fixture.support + "/daemon-status.json")
        )
        XCTAssertEqual(status.result, "failed")
        XCTAssertTrue(status.detail.contains("repository"))
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = SyncSetupModel(context: container.mainContext, root: fixture.root,
                                   lockPath: fixture.support + "/sync.lock")
        let spec = try XCTUnwrap(SyncSetupModel.parseRemote("git@example.com:other.git"))
        XCTAssertThrowsError(try model.perform(spec: spec, credential: .sshAgent)) {
            assertRepositoryFailure($0, fixture: fixture)
        }
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testConnectUnknownRemoteNeverRunsMutationCommand() throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let before = try fixture.snapshot()
        let git = try fixture.executable("""
            if [ "$3" = 'remote' ] && [ "$4" = 'get-url' ]; then
                echo 'could not read repository config' >&2
                exit 128
            fi
            exec /usr/bin/git "$@"
            """)
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = SyncSetupModel(context: container.mainContext, git: git,
                                   credentials: InMemoryCredentialStore(), root: fixture.root,
                                   lockPath: fixture.support + "/sync.lock")
        let spec = try XCTUnwrap(SyncSetupModel.parseRemote("git@example.com:other.git"))
        XCTAssertThrowsError(try model.perform(spec: spec, credential: .sshAgent)) {
            assertRepositoryFailure($0, fixture: fixture)
        }
        let calls = try fixture.files.readFile(at: fixture.trace)
        XCTAssertFalse(calls.contains("remote add"))
        XCTAssertFalse(calls.contains("remote set-url"))
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testConflictApplyRechecksRemoteBeforePassingCredential() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository(remote: "git@example.com:store.git")
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let spy = GitFailureEngineSpy()
        let model = ConflictResolutionModel(engine: spy, root: fixture.root)
        await model.loadAndReport(context: container.mainContext)
        guard case let .ready(groups) = model.phase, let group = groups.first else { return XCTFail("missing conflict") }
        model.choose(group.id, .thisMachine)
        try fixture.files.deleteFile(at: fixture.root + "/.git/HEAD")
        let before = try fixture.snapshot()
        await model.applyAndReport(context: container.mainContext)
        guard case let .error(message) = model.phase else { return XCTFail("must fail before resolve") }
        XCTAssertTrue(message.contains("repository"))
        XCTAssertEqual(spy.calls, 1, "only the successful initial inspection may reach the engine")
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testGitFailureAfterManifestWriteLeavesReadableStoreAndNextCycleSyncs() throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository(remote: nil)
        let remote = fixture.base + "/remote.git"
        try GitService().runOrThrow(["init", "--bare", "--initial-branch=main", remote], in: nil)
        try GitService().setRemote(remote, at: fixture.root)
        try GitService().push(at: fixture.root, credential: nil)
        let git = try fixture.executable("""
            if [ -f '\(fixture.failureSwitch)' ]; then
                echo 'Xcode license: sudo xcodebuild -license' >&2
                exit 69
            fi
            exec /usr/bin/git "$@"
            """)
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let manifest = GitFailureManifest(fixture: fixture)
        let engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: git), manifestService: manifest,
                                lockPath: fixture.support + "/sync.lock")
        XCTAssertThrowsError(try engine.sync(root: fixture.root, message: "test", credential: nil,
                                             context: container.mainContext)) {
            XCTAssertTrue($0.localizedDescription.contains("Git isn't working"))
            XCTAssertTrue($0.localizedDescription.contains("sudo xcodebuild -license"))
        }
        XCTAssertTrue(manifest.didWrite)
        XCTAssertNoThrow(try ManifestService().read(fromRoot: fixture.root))
        try fixture.files.deleteFile(at: fixture.failureSwitch)
        let recovered = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: git), lockPath: fixture.support + "/sync.lock")
        guard case .synced = try recovered.sync(root: fixture.root, message: "recovered", credential: nil,
                                                context: container.mainContext) else { return XCTFail("must sync") }
        let remoteHead = try GitService().runOrThrow(["--git-dir", remote, "rev-parse", "HEAD"], in: nil).stdout
        XCTAssertEqual(remoteHead.trimmingCharacters(in: .whitespacesAndNewlines), try git.commitSHA(at: fixture.root))
    }

    func testSyncCommandHintRequiresAConfirmingProbe() throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let git = try fixture.executable("""
            if [ "$3" = 'add' ]; then
                echo "checkout failed for 'xcrun: error: invalid active developer path'" >&2
                exit 128
            fi
            exec /usr/bin/git "$@"
            """)
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: git),
                                lockPath: fixture.support + "/sync.lock")
        XCTAssertThrowsError(try engine.sync(root: fixture.root, message: "test", credential: nil,
                                             context: container.mainContext)) { error in
            guard case GitError.commandFailed = error else { return XCTFail("the usable probe must retain the command error") }
            XCTAssertFalse(error.localizedDescription.contains("Git isn't working"))
        }
        let trace = try fixture.files.readFile(at: fixture.trace)
        XCTAssertEqual(trace.components(separatedBy: "--version").count - 1, 2,
                       "preflight and failure confirmation must both run the real probe")
    }

    private func runDaemon(_ fixture: GitFailureFixture, git: GitService) -> CLIOutcome {
        let daemon = SyncDaemon(root: fixture.root, appSupport: fixture.support, git: git,
                                credentials: InMemoryCredentialStore(), reconciler: GitFailureReconciler(), now: Date.init)
        return DaemonCLI.execute(["run"], appSupport: fixture.support,
                                 readFile: { try? fixture.files.readData(at: $0) }, runCycle: daemon.runOnce, now: Date.init)
    }
}

private func assertRepositoryFailure(_ error: Error, fixture: GitFailureFixture,
                                     file: StaticString = #filePath, line: UInt = #line) {
    guard case let GitError.repositoryUnreadable(path, _) = error else {
        return XCTFail("expected repository failure, got \(error)", file: file, line: line)
    }
    XCTAssertEqual(path, fixture.root, file: file, line: line)
}

private struct GitFailureReconciler: DeployReconciling {
    func reconcile(root: String) throws -> ReconcileOutcome {
        XCTFail("a failed or unconfigured cycle must never reconcile")
        return ReconcileOutcome()
    }
}

private final class GitFailureEngineSpy: SyncEngineProtocol {
    var calls = 0
    func sync(root: String, message: String, credential: GitCredential?, context: ModelContext,
              prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome {
        calls += 1
        return .synced(pushed: false, warnings: [])
    }
    func inspectConflicts(root: String, credential: GitCredential?, context: ModelContext) throws -> ConflictInspection {
        calls += 1
        return .conflicts(ConflictSet(items: [
            ConflictItem(path: "skills/example/SKILL.md", kind: .body, thisMachine: "local", otherMachine: "remote")
        ]))
    }
    func resolveConflicts(root: String, picks: [String: ResolutionPick], credential: GitCredential?,
                          context: ModelContext) throws -> SyncOutcome {
        calls += 1
        return .noRemote
    }
}

private final class GitFailureManifest: ManifestSnapshotting {
    let fixture: GitFailureFixture
    var didWrite = false
    init(fixture: GitFailureFixture) { self.fixture = fixture }
    func read(fromRoot root: String) throws -> ManifestSnapshot { try ManifestService().read(fromRoot: root) }
    func snapshot(from context: ModelContext) throws -> ManifestSnapshot { try ManifestService().snapshot(from: context) }
    func write(_ snapshot: ManifestSnapshot, toRoot root: String) throws {
        try ManifestService().write(snapshot, toRoot: root)
        didWrite = true
        try fixture.files.writeFile(at: fixture.failureSwitch, content: "fail subsequent git calls")
    }
}
