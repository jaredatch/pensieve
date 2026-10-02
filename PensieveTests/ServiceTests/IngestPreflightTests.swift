import Foundation
import SwiftData
import XCTest
@testable import Pensieve

private typealias IngestCategory = Pensieve.Category

private final class ReadinessRecordingEngine: SyncEngineProtocol {
    private(set) var syncCalls = 0

    func sync(root: String, message: String, credential: GitCredential?, context: ModelContext,
              prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome {
        syncCalls += 1
        try prepare?(context)
        return .synced(pushed: false, warnings: [])
    }

    func inspectConflicts(root: String, credential: GitCredential?,
                          context: ModelContext) throws -> ConflictInspection {
        fatalError("unused")
    }

    func resolveConflicts(root: String, picks: [String: ResolutionPick],
                          credential: GitCredential?, context: ModelContext) throws -> SyncOutcome {
        fatalError("unused")
    }
}

@MainActor
final class IngestPreflightTests: XCTestCase {
    var tempDir = ""

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveIngestPreflight-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if !tempDir.isEmpty { try? FileManager.default.removeItem(atPath: tempDir) }
    }

    func testSingleLockAcquisitionPerCycle() throws {
        let lockPath = tempDir + "/sync.lock"
        var acquisitionCount = 0
        let engine = recordingEngine(lockPath: lockPath) { path in
            acquisitionCount += 1
            return SyncLock.tryAcquire(at: path)
        }
        var prepareCalls = 0

        _ = try engine.sync(root: tempDir, message: "test", credential: nil,
                            context: context()) { _ in
            prepareCalls += 1
            XCTAssertNil(SyncLock.tryAcquire(at: lockPath), "prepare must share the engine-owned lock")
        }

        XCTAssertEqual(prepareCalls, 1)
        XCTAssertEqual(acquisitionCount, 1, "one sync cycle must request the lock exactly once")
        let released = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
        released.release()
    }

    func testPrepareRunsUnderLockBeforeSnapshot() throws {
        let lockPath = tempDir + "/sync.lock"
        let manifest = IngestRecordingManifest()
        let engine = recordingEngine(lockPath: lockPath, manifest: manifest)

        _ = try engine.sync(root: tempDir, message: "test", credential: nil,
                            context: context()) { _ in
            XCTAssertNil(SyncLock.tryAcquire(at: lockPath))
            manifest.events.append("prepare")
        }

        XCTAssertEqual(manifest.events, ["read", "prepare", "snapshot", "write"])
    }

    func testGuardRejectedCycleNeverInvokesPrepare() throws {
        var prepareCalls = 0
        let prepare: (ModelContext) throws -> Void = { _ in prepareCalls += 1 }

        let noRemoteGit = IngestRecordingGit()
        noRemoteGit.remote = nil
        _ = try recordingEngine(git: noRemoteGit, lockPath: tempDir + "/no-remote.lock")
            .sync(root: tempDir, message: "test", credential: nil, context: context(), prepare: prepare)

        let rejectedGit = IngestRecordingGit()
        rejectedGit.remote = "file:///rejected"
        XCTAssertThrowsError(
            try recordingEngine(git: rejectedGit, lockPath: tempDir + "/rejected.lock")
                .sync(root: tempDir, message: "test", credential: nil, context: context(), prepare: prepare)
        )

        let unreadable = IngestRecordingManifest()
        unreadable.readError = IngestPreflightBoom.expected
        XCTAssertThrowsError(
            try recordingEngine(lockPath: tempDir + "/unreadable.lock", manifest: unreadable)
                .sync(root: tempDir, message: "test", credential: nil, context: context(), prepare: prepare)
        )
        XCTAssertEqual(prepareCalls, 0)
    }

    func testPrepareThrowMakesNoSnapshotOrGitWrites() throws {
        let git = IngestRecordingGit()
        let manifest = IngestRecordingManifest()
        let lockPath = tempDir + "/sync.lock"
        let engine = recordingEngine(git: git, lockPath: lockPath, manifest: manifest)

        XCTAssertThrowsError(
            try engine.sync(root: tempDir, message: "test", credential: nil,
                            context: context()) { _ in throw IngestPreflightBoom.expected }
        )
        XCTAssertEqual(manifest.events, ["read"])
        XCTAssertTrue(git.calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir + "/.gitattributes"))
        let released = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
        released.release()
    }

    func testCoordinatorReadyFirstWaitsForLaunchIngest() async {
        await assertReadinessOrder(coordinatorFirst: true)
    }

    func testLaunchIngestFirstWaitsForCoordinatorReady() async {
        await assertReadinessOrder(coordinatorFirst: false)
    }

    func testCoordinatorNeverSamplesIngestedStampAfterEngineUnlock() async throws {
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let coordinator = await Task.detached { SyncCoordinator(modelContainer: container) }.value
        let rebuild = IngestRecordingRebuild()
        let engine = ReadinessRecordingEngine()
        var stamp = "before"
        var stampReads = 0
        await coordinator.configure(
            engine: engine,
            git: IngestRecordingGit(),
            credentials: IngestEmptyCredentials(),
            rebuildService: rebuild,
            root: tempDir,
            audit: IngestNullAudit(),
            machineIdentity: InertMachineIdentity(),
            machineStateService: InertMachineStateService(),
            headStamp: {
                stampReads += 1
                return stamp
            }
        )
        await coordinator.seedLastIngestedHeadStamp(stamp)

        guard case let .synced(_, _, _, firstHeadAdvanced) = await coordinator.runCycle() else {
            return XCTFail("first cycle did not sync")
        }
        XCTAssertFalse(firstHeadAdvanced)
        XCTAssertEqual(stampReads, 1, "HEAD is sampled only by prepare while the engine owns the lock")

        stamp = "after"
        guard case let .synced(_, _, _, secondHeadAdvanced) = await coordinator.runCycle() else {
            return XCTFail("second cycle did not sync")
        }
        XCTAssertTrue(secondHeadAdvanced)
        XCTAssertEqual(rebuild.calls, 1, "an unlocked HEAD advance remains un-ingested until preflight")
    }

    func testUnreadableHeadStampForcesPreflight() async throws {
        XCTAssertNil(GitHeadStamp().read(root: tempDir))
        let fileService = FileService()
        try fileService.createDirectory(at: tempDir + "/.git/refs/heads")
        try fileService.writeFile(at: tempDir + "/.git/HEAD", content: "ref: refs/heads/alias\n")
        try fileService.writeFile(
            at: tempDir + "/.git/refs/heads/alias",
            content: "ref: refs/heads/main\n"
        )
        try fileService.writeFile(
            at: tempDir + "/.git/refs/heads/main",
            content: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"
        )
        XCTAssertNil(GitHeadStamp().read(root: tempDir), "a chained symbolic ref is not an OID stamp")
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let coordinator = await Task.detached { SyncCoordinator(modelContainer: container) }.value
        let rebuild = IngestRecordingRebuild()
        await coordinator.configure(
            engine: ReadinessRecordingEngine(),
            git: IngestRecordingGit(),
            credentials: IngestEmptyCredentials(),
            rebuildService: rebuild,
            root: tempDir,
            audit: IngestNullAudit(),
            machineIdentity: InertMachineIdentity(),
            machineStateService: InertMachineStateService(),
            headStamp: { GitHeadStamp().read(root: self.tempDir) }
        )
        await coordinator.seedLastIngestedHeadStamp("previous")

        guard case .synced = await coordinator.runCycle() else {
            return XCTFail("cycle did not sync")
        }
        XCTAssertEqual(rebuild.calls, 1)
    }

    private func assertReadinessOrder(coordinatorFirst: Bool) async {
        let fired = expectation(description: "both readiness gates open")
        let engine = ReadinessRecordingEngine()
        let context = try? context()
        let scheduler = SyncScheduler(
            debounceSeconds: 0,
            startAutomatically: false,
            backgroundSyncEnabled: { true }
        )
        scheduler.installDrain {
            if let context {
                _ = try? engine.sync(
                    root: self.tempDir,
                    message: "readiness",
                    credential: nil,
                    context: context
                )
            }
            fired.fulfill()
        }
        if coordinatorFirst {
            scheduler.coordinatorBecameReady()
        } else {
            scheduler.launchIngestCompleted()
        }
        await Task.yield()
        XCTAssertEqual(engine.syncCalls, 0)
        if coordinatorFirst {
            scheduler.launchIngestCompleted()
        } else {
            scheduler.coordinatorBecameReady()
        }
        await fulfillment(of: [fired], timeout: 1)
        XCTAssertEqual(engine.syncCalls, 1)
    }

    private func context() throws -> ModelContext {
        ModelContext(try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        ))
    }

    private func recordingEngine(
        git: IngestRecordingGit = IngestRecordingGit(),
        lockPath: String,
        manifest: IngestRecordingManifest = IngestRecordingManifest(),
        lockProvider: @escaping (String) -> SyncLock? = { SyncLock.tryAcquire(at: $0) }
    ) -> SyncEngine {
        SyncEngine(
            gitService: git,
            manifestService: manifest,
            storeRebuildService: IngestNoopRebuild(),
            fileService: FileService(),
            lockPath: lockPath,
            lockProvider: lockProvider
        )
    }
}
