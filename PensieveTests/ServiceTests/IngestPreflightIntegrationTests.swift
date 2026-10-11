import Foundation
import SwiftData
import XCTest
@testable import Pensieve

private typealias IntegrationCategory = Pensieve.Category

extension IngestPreflightTests {
    func testExternalFastForwardNotRevertedBySnapshot() async throws {
        let harness = try makeGitHarness(name: "external")
        let app = tempDir + "/app"
        let cli = tempDir + "/cli"
        try NativeTestWork.run { try harness.git.clone(remote: harness.remote, into: app, credential: nil) }
        try NativeTestWork.run { try harness.git.clone(remote: harness.remote, into: cli, credential: nil) }

        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let appContext = ModelContext(container)
        _ = StoreRebuildService().rebuild(fromRoot: app, context: appContext)
        let initialStamp = GitHeadStamp().read(root: app)

        try harness.manifest.write(
            ManifestSnapshot(
                schemaVersion: ManifestService.currentSchemaVersion,
                categories: [CategoryRecord(name: "Pulled", projectKeys: [], skillSlugs: [])],
                projects: [], skills: []
            ),
            toRoot: cli
        )
        XCTAssertTrue(try NativeTestWork.run { try harness.git.stageAllAndCommit(at: cli, message: "external fast-forward") })
        try NativeTestWork.run { try harness.git.push(at: cli, credential: nil) }
        guard case .fastForwarded = (try NativeTestWork.run { try harness.git.fastForwardOnly(at: app, credential: nil) }) else {
            return XCTFail("simulated CLI did not fast-forward")
        }
        XCTAssertTrue(try appContext.fetch(FetchDescriptor<IntegrationCategory>()).isEmpty,
                      "the app context must still be stale before the resident cycle")

        let engine = SyncEngine(
            gitService: AllowlistedRemoteGit(wrapping: harness.git),
            manifestService: harness.manifest,
            storeRebuildService: StoreRebuildService(),
            fileService: FileService(),
            lockPath: tempDir + "/external-sync.lock"
        )
        let coordinator = await Task.detached { SyncCoordinator(modelContainer: container) }.value
        await coordinator.configure(
            engine: engine,
            git: harness.git,
            credentials: IngestEmptyCredentials(),
            rebuildService: StoreRebuildService(),
            root: app,
            audit: IngestNullAudit(),
            machine: (identity: InertMachineIdentity(), stateService: InertMachineStateService())
        )
        await coordinator.seedLastIngestedHeadStamp(initialStamp)
        guard case .synced = await coordinator.runCycle() else {
            return XCTFail("resident cycle did not sync")
        }

        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<IntegrationCategory>()).map(\.name), ["Pulled"])
        let remoteCheck = tempDir + "/remote-check"
        try NativeTestWork.run { try harness.git.clone(remote: harness.remote, into: remoteCheck, credential: nil) }
        XCTAssertEqual(try harness.manifest.read(fromRoot: remoteCheck).categories.map(\.name), ["Pulled"])
    }

    func testDirtyPrepareWriteRecoveredOnRetry() throws {
        let harness = try makeGitHarness(name: "recovery")
        let app = tempDir + "/recovery-app"
        try NativeTestWork.run { try harness.git.clone(remote: harness.remote, into: app, credential: nil) }
        let lockPath = tempDir + "/recovery-sync.lock"
        let engine = SyncEngine(
            gitService: AllowlistedRemoteGit(wrapping: harness.git),
            manifestService: harness.manifest,
            storeRebuildService: StoreRebuildService(),
            fileService: FileService(),
            lockPath: lockPath
        )
        let statePath = app + "/machines/recovery.yaml"
        let fileService = FileService()

        XCTAssertThrowsError(
            try NativeTestWork.run(container: try integrationContext().container) { [self] jobContext in
                try engine.sync(root: app, message: "crash", credential: nil,
                    context: jobContext) { _ in
                    try fileService.createDirectory(at: app + "/machines")
                    try fileService.writeFile(at: statePath, content: "prepared: true\n")
                    throw IngestPreflightBoom.expected
                    }
            }
        )
        XCTAssertFalse(try NativeTestWork.run { try harness.git.isWorktreeClean(at: app) })
        let daemon = SyncDaemon(
            root: app,
            appSupport: tempDir + "/daemon-support",
            git: IngestAllowlistedFastForwardGit(git: harness.git),
            hasLocalBranches: { try harness.git.hasLocalBranches(at: $0) },
            credentials: IngestEmptyCredentials(),
            reconciler: IngestNoopDeploy(),
            now: Date.init
        )
        XCTAssertEqual(try NativeTestWork.run { daemon.runOnce() }, .skipped(.dirtyTree))

        let outcome = try NativeTestWork.run(container: try integrationContext().container) { [self] jobContext in
            try engine.sync(
                root: app,
                message: "retry",
                credential: nil,
                context: jobContext
                )
        }
        guard case .synced = outcome else { return XCTFail("retry did not sync") }
        XCTAssertTrue(try NativeTestWork.run { try harness.git.isWorktreeClean(at: app) })

        let peer = tempDir + "/recovery-peer"
        try NativeTestWork.run { try harness.git.clone(remote: harness.remote, into: peer, credential: nil) }
        XCTAssertEqual(try fileService.readFile(at: peer + "/machines/recovery.yaml"), "prepared: true\n")
    }

    private func integrationContext() throws -> ModelContext {
        ModelContext(try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        ))
    }

    private struct GitHarness {
        let git: GitService
        let manifest: ManifestService
        let remote: String
    }

    private func makeGitHarness(name: String) throws -> GitHarness {
        let remotePath = tempDir + "/\(name)-remote.git"
        _ = try ingestRawGit(["init", "--bare", remotePath])
        let remote = "file://" + remotePath
        let seed = tempDir + "/\(name)-seed"
        try FileManager.default.createDirectory(atPath: seed, withIntermediateDirectories: true)
        let git = TestPaths.git
        let manifest = ManifestService()
        try NativeTestWork.run { try git.initRepository(at: seed) }
        try NativeTestWork.run { try git.setRemote(remote, at: seed) }
        try manifest.write(
            ManifestSnapshot(
                schemaVersion: ManifestService.currentSchemaVersion,
                categories: [], projects: [], skills: []
            ),
            toRoot: seed
        )
        try FileService().writeFile(
            at: seed + "/.gitattributes",
            content: "manifest/categories/*.yaml merge=union\nmanifest/scenarios/*.yaml merge=union\n"
                + "manifest/projects.yaml merge=union\n"
        )
        try FileService().writeFile(at: seed + "/.gitignore", content: ".DS_Store\n")
        XCTAssertTrue(try NativeTestWork.run { try git.stageAllAndCommit(at: seed, message: "seed") })
        try NativeTestWork.run { try git.push(at: seed, credential: nil) }
        return GitHarness(git: git, manifest: manifest, remote: remote)
    }
}
