import SwiftData
import XCTest
@testable import Pensieve

private final class RecordingHeadRetryRebuildService: StoreRebuildServiceProtocol {
    private let fileService: FileServiceProtocol
    private let refPath: String
    private let mutateOnFirstCall: Bool
    private let firstResult: RebuildResult
    private let secondResult: RebuildResult
    private(set) var calls = 0

    init(fileService: FileServiceProtocol,
         refPath: String,
         mutateOnFirstCall: Bool,
         firstResult: RebuildResult,
         secondResult: RebuildResult) {
        self.fileService = fileService
        self.refPath = refPath
        self.mutateOnFirstCall = mutateOnFirstCall
        self.firstResult = firstResult
        self.secondResult = secondResult
    }

    func rebuild(fromRoot root: String, context: ModelContext) -> RebuildResult {
        calls += 1
        if calls == 1, mutateOnFirstCall {
            try? fileService.writeFile(
                at: refPath,
                content: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n"
            )
        }
        return calls == 1 ? firstResult : secondResult
    }
}

private final class RecordingHeadRetryMigrationService: StoreMigrationServiceProtocol {
    private(set) var calls = 0

    func migrateIfNeeded(fromRoot root: String, context: ModelContext) -> MigrationResult {
        calls += 1
        return MigrationResult(skillsMigrated: 0, manifestWritten: true, warnings: [])
    }
}

private final class DefiniteBornHeadRetryGitService: GitServiceProtocol {
    func initRepository(at path: String) throws {}
    func setRemote(_ url: String, at path: String) throws {}
    func removeRemote(at path: String) throws {}
    func configuredRemoteURL(at path: String) throws -> String? { nil }
    func remoteURL(at path: String) -> String? { nil }
    func clone(remote: String, into path: String, credential: GitCredential?) throws {}
    func remoteHasCommits(remote: String, credential: GitCredential?) -> Bool { false }
    func hasLocalBranches(at path: String) throws -> Bool {
        true
    }

    func hasRemoteOriginConfigured(at path: String) throws -> Bool {
        false
    }
    func stageAllAndCommit(at path: String, message: String) throws -> Bool { false }
    func preflightStoreUpdate(at path: String, credential: GitCredential?) -> FetchedStoreRevision? { nil }
    func pullRebase(at path: String, fetchedRevision: FetchedStoreRevision) throws -> PullResult {
        try pullRebase(at: path, credential: nil)
    }
    func pullRebase(at path: String, credential: GitCredential?) throws -> PullResult { .upToDate }
    func push(at path: String, credential: GitCredential?) throws {}
    func abortRebase(at path: String) throws {}
    func conflictedFiles(at path: String) -> [String] { [] }
    func blob(atStage stage: Int, path: String, in workingDir: String) -> Data? { nil }
    func continueRebase(at path: String) throws -> PullResult { .upToDate }
    func skipRebase(at path: String) throws -> PullResult { .upToDate }
    func stagePath(_ path: String, at root: String) throws {}
    func collapseToSingleCommit(at root: String, message: String,
                                credential: GitCredential?, fetchedRevision: FetchedStoreRevision?) throws -> Bool { false }
    func hasCommitsToPush(at path: String) -> Bool { false }
}

final class LaunchReconcilerHeadRetryTests: XCTestCase {
    private var tempDir: String!
    private var fileService: FileService!
    private var manifest: ManifestService!
    private var migrationService: StoreMigrationService!

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveLaunchHeadRetryTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        fileService = FileService()
        manifest = ManifestService(fileService: fileService)
        migrationService = StoreMigrationService(
            fileService: fileService,
            manifestService: manifest,
            skillStore: SkillStore(fileService: fileService, baseDir: tempDir + "/skills", storeRoot: tempDir)
        )
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self, DeployRecord.self, Category.self, Scenario.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    // Launch-rebuild hardening (12.10 fold-in): if the daemon fast-forwards the repo while the GUI is
    // rebuilding from disk, the first rebuild may have read a torn manifest. A single HEAD-stamp retry
    // converges on the post-pull state without taking the sync lock during app startup.
    @MainActor
    func testLaunchRebuildRetriesOnceWhenHeadAdvancesMidRebuild() throws {
        let ctx = try makeContext()
        let refPath = try seedManifestAndHead()
        var first = RebuildResult()
        first.skillsInserted = 1
        var second = RebuildResult()
        second.skillsInserted = 2
        let rebuild = RecordingHeadRetryRebuildService(
            fileService: fileService,
            refPath: refPath,
            mutateOnFirstCall: true,
            firstResult: first,
            secondResult: second
        )
        let rec = LaunchReconciler(
            rebuildService: rebuild,
            migrationService: migrationService,
            fileService: fileService,
            manifestService: manifest,
            root: tempDir,
            lockPath: tempDir + "/sync.lock",
            git: DefiniteBornHeadRetryGitService()
        )

        let outcome = rec.reconcileOnLaunch(context: ctx, alreadyMigrated: true)

        XCTAssertEqual(rebuild.calls, 2)
        XCTAssertEqual(outcome.rebuild.skillsInserted, 2)
    }

    // The retry is bounded: when HEAD is stable across the rebuild, the launch path runs the rebuild
    // exactly once and returns that result.
    @MainActor
    func testLaunchRebuildRunsOnceWhenHeadStable() throws {
        let ctx = try makeContext()
        let refPath = try seedManifestAndHead()
        var first = RebuildResult()
        first.skillsInserted = 1
        var second = RebuildResult()
        second.skillsInserted = 2
        let rebuild = RecordingHeadRetryRebuildService(
            fileService: fileService,
            refPath: refPath,
            mutateOnFirstCall: false,
            firstResult: first,
            secondResult: second
        )
        let rec = LaunchReconciler(
            rebuildService: rebuild,
            migrationService: migrationService,
            fileService: fileService,
            manifestService: manifest,
            root: tempDir,
            lockPath: tempDir + "/sync.lock",
            git: DefiniteBornHeadRetryGitService()
        )

        let outcome = rec.reconcileOnLaunch(context: ctx, alreadyMigrated: true)

        XCTAssertEqual(rebuild.calls, 1)
        XCTAssertEqual(outcome.rebuild.skillsInserted, 1)
    }

    // Layer-1 review hardening (12.10): the one-time migration writes the baseline manifest, so it must not
    // write after the repo advances between the launch rebuild and the migration guard. It skips instead and
    // retries on the next launch.
    @MainActor
    func testMigrationSkipsWhenHeadAdvancesAfterRebuild() throws {
        let ctx = try makeContext()
        _ = try seedManifestAndHead()
        var first = RebuildResult()
        first.skillsInserted = 1
        let rebuild = RecordingHeadRetryRebuildService(
            fileService: fileService,
            refPath: tempDir + "/.git/refs/heads/main",
            mutateOnFirstCall: false,
            firstResult: first,
            secondResult: RebuildResult()
        )
        let migration = RecordingHeadRetryMigrationService()
        var stamps = ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]
        let rec = LaunchReconciler(
            rebuildService: rebuild,
            migrationService: migration,
            fileService: fileService,
            manifestService: manifest,
            root: tempDir,
            lockPath: tempDir + "/sync.lock",
            git: DefiniteBornHeadRetryGitService(),
            headStampOverride: { stamps.isEmpty ? stamps.last ?? "" : stamps.removeFirst() }
        )

        let outcome = rec.reconcileOnLaunch(context: ctx, alreadyMigrated: false)

        XCTAssertEqual(rebuild.calls, 1)
        XCTAssertEqual(migration.calls, 0)
        XCTAssertFalse(outcome.migrationRan)
        XCTAssertNil(outcome.ingestedHeadStamp)
    }

    // PLAN-23 / 23.3 fix-round regression: AppRuntime now holds sync.lock across the whole launch
    // reconcile. The reconciler's final-head validation must use that externally held lock instead of
    // acquiring the non-reentrant lock itself — re-acquiring under the held lock necessarily fails and
    // would mark ingestion needs-retry on EVERY production launch, permanently blocking resident sync.
    @MainActor
    func testHeldLockLaunchIngestionCompletes() throws {
        let ctx = try makeContext()
        let refPath = try seedManifestAndHead()
        var first = RebuildResult()
        first.skillsInserted = 1
        let rebuild = RecordingHeadRetryRebuildService(
            fileService: fileService,
            refPath: refPath,
            mutateOnFirstCall: false,
            firstResult: first,
            secondResult: RebuildResult()
        )
        let lockPath = tempDir + "/sync.lock"
        let rec = LaunchReconciler(
            rebuildService: rebuild,
            migrationService: migrationService,
            fileService: fileService,
            manifestService: manifest,
            root: tempDir,
            lockPath: lockPath,
            git: DefiniteBornHeadRetryGitService()
        )
        let outerLock = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
        defer { outerLock.release() }

        let parent = (tempDir as NSString).deletingLastPathComponent
        let cloneTemp = parent + "/.pensieve-clone-" + UUID().uuidString
        let vendorTemp = tempDir + ".vendor-" + UUID().uuidString + ".tmp"
        let sentinel = parent + "/.pensieve-clone-backup-" + UUID().uuidString
        for path in [cloneTemp, vendorTemp, sentinel] { try fileService.writeFile(at: path + "/keep", content: "bytes") }
        defer { for path in [cloneTemp, vendorTemp, sentinel] { try? fileService.deleteDirectory(at: path) } }

        // Without the vouch, validation self-conflicts against the outer lock: needs-retry forever.
        let conflicted = rec.reconcileOnLaunch(context: ctx, alreadyMigrated: true)
        XCTAssertTrue(conflicted.ingestionNeedsRetry)
        XCTAssertNil(conflicted.ingestedHeadStamp)
        XCTAssertTrue(fileService.directoryExists(at: cloneTemp))
        XCTAssertTrue(fileService.directoryExists(at: vendorTemp))

        // With the vouch, ingestion completes under the caller's lock.
        let completed = rec.reconcileOnLaunch(
            context: ctx, alreadyMigrated: true, externallyHeldLock: true
        )
        XCTAssertFalse(completed.ingestionNeedsRetry)
        XCTAssertNotNil(completed.ingestedHeadStamp)
        XCTAssertFalse(fileService.directoryExists(at: cloneTemp), "Launch must sweep under its caller's held lock")
        XCTAssertFalse(fileService.directoryExists(at: vendorTemp), "Vendor cleanup shares the held-lock contract")
        XCTAssertEqual(try fileService.readFile(at: sentinel + "/keep"), "bytes")
        XCTAssertNil(SyncLock.tryAcquire(at: lockPath), "Cleanup must not release the caller's lock")
    }

    private func seedManifestAndHead() throws -> String {
        try manifest.write(
            ManifestSnapshot(schemaVersion: 1, categories: [], projects: [], skills: []),
            toRoot: tempDir
        )
        let refPath = tempDir + "/.git/refs/heads/main"
        try fileService.writeFile(at: tempDir + "/.git/HEAD", content: "ref: refs/heads/main\n")
        try fileService.writeFile(at: refPath, content: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n")
        return refPath
    }
}
