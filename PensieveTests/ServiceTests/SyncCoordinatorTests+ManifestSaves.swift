import SwiftData
import XCTest
@testable import Pensieve

@MainActor
extension SyncCoordinatorTests {
    func testQueuedCategoryEditBetweenPullAndRebuildSurvivesNextCommit() async throws {
        let h = try makeRemoteHarness()
        let lockPath = h.clone + "/../support/sync.lock"
        let manifest = ManifestService()
        let context = h.container.mainContext
        let local = Pensieve.Category(name: "Local")
        context.insert(local)
        try context.save()
        try manifest.write(try manifest.snapshot(from: context), toRoot: h.clone)
        let gate = TestWait.Gate(owner: self)
        defer { gate.open() }
        let engine = SyncEngine(gitService: h.allowlistedGit, manifestService: manifest,
            storeRebuildService: PausedManifestRebuild(gate: gate), lockPath: lockPath)
        let coordinator = await configuredCoordinator(container: h.container, engine: engine,
            git: h.allowlistedGit, root: h.clone)
        // The first engine rebuild also passes the gate; the next one pauses after the pull.
        gate.open()
        assertSynced(await coordinator.runCycle())
        try publishRemoteCategory(h)
        let saves = ManifestSaveModel(manifest: manifest, root: h.clone, lockPath: lockPath)
        let store = CategoryStore( manifestSaves: saves)
        let cycle = Task { await coordinator.runCycle() }
        await TestWait.until(failureMessage: "Sync did not pause between pull and rebuild") { gate.waiterCount == 1 }
        XCTAssertTrue(try manifest.read(fromRoot: h.clone).categories.contains { $0.name == "Remote" })
        store.rename(local, to: "Edited", context: context)
        XCTAssertEqual(local.name, "Edited")
        await Task.yield()
        XCTAssertFalse(try manifest.read(fromRoot: h.clone).categories.contains { $0.name == "Edited" })
        gate.open()
        assertSynced(await cycle.value)
        await saves.waitUntilIdle()
        gate.open()
        assertSynced(await coordinator.runCycle())
        try assertCommittedBoth(h, context: context)
    }

    func testDaemonFastForwardWhileCategorySaveWaitsKeepsBothInNextAppCommit() async throws {
        let h = try makeRemoteHarness()
        let support = h.clone + "/../support"
        let lockPath = support + "/sync.lock"
        let manifest = ManifestService()
        let context = h.container.mainContext
        let local = Pensieve.Category(name: "Local")
        context.insert(local)
        try context.save()
        try manifest.write(try manifest.snapshot(from: context), toRoot: h.clone)
        let coordinator = await configuredCoordinator(container: h.container,
            engine: SyncEngine(gitService: h.allowlistedGit, lockPath: lockPath), git: h.allowlistedGit, root: h.clone)
        assertSynced(await coordinator.runCycle())
        try publishRemoteCategory(h)
        let gate = TestWait.Gate(owner: self)
        defer { gate.open() }
        let daemon = SyncDaemon(root: h.clone, appSupport: support,
            git: PausedManifestFastForward(wrapped: AllowlistedFastForwardGit(wrapping: h.git), gate: gate),
            hasLocalBranches: h.git.hasLocalBranches, credentials: InMemoryCredentialStore(),
            reconciler: DeployReconciler(fileService: FileService(), deployState: .memoryBacked,
                pensieveSkillsDir: h.clone + "/skills", agentSkillDirs: [], cursorRulesDir: support + "/rules",
                manifestService: manifest), now: Date.init)
        let run = BlockingWork.task { daemon.runOnce() }
        await TestWait.until(failureMessage: "Daemon did not hold the lock before fast-forward") { gate.waiterCount == 1 }
        let saves = ManifestSaveModel(manifest: manifest, root: h.clone, lockPath: lockPath)
        CategoryStore( manifestSaves: saves)
            .rename(local, to: "Edited", context: context)
        await Task.yield()
        XCTAssertEqual(try manifest.read(fromRoot: h.clone).categories.map(\.name), ["Local"])
        gate.open()
        let outcome = await run.value
        XCTAssertEqual(outcome, .synced(changed: true))
        await saves.waitUntilIdle()
        assertSynced(await coordinator.runCycle())
        try assertCommittedBoth(h, context: context)
    }

    private func publishRemoteCategory(_ h: RemoteHarness) throws {
        let peer = h.clone + "-peer"
        try NativeTestWork.run { [self] in try h.git.clone(remote: h.remote, into: peer, credential: nil) }
        let manifest = ManifestService()
        var snapshot = try manifest.read(fromRoot: peer)
        snapshot.categories[0].projectKeys = ["pulled-project"]
        snapshot.categories.append(CategoryRecord(name: "Remote", projectKeys: [], skillSlugs: []))
        try manifest.write(snapshot, toRoot: peer)
        XCTAssertTrue(try NativeTestWork.run { [self] in try h.git.stageAllAndCommit(at: peer, message: "peer category") })
        try NativeTestWork.run { [self] in try h.git.push(at: peer, credential: nil) }
    }

    private func assertCommittedBoth(_ h: RemoteHarness, context: ModelContext,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let names = try rawGitOutput(["--git-dir", h.remotePath, "ls-tree", "-r", "--name-only", "HEAD", "manifest/categories"])
        let expected = ["Edited", "Remote"].map { "manifest/categories/" + ManifestService.categoryFileName($0) }
        XCTAssertEqual(Set(names.split(separator: "\n").map(String.init)), Set(expected), file: file, line: line)
        let edited = try rawGitOutput(["--git-dir", h.remotePath, "show", "HEAD:" + expected[0]])
        XCTAssertTrue(edited.contains("pulled-project"), file: file, line: line)
        let window = try context.fetch(FetchDescriptor<Pensieve.Category>())
        XCTAssertEqual(Set(window.map(\.name)), ["Edited", "Remote"], file: file, line: line)
        XCTAssertEqual(window.first { $0.name == "Edited" }?.projectKeys, ["pulled-project"], file: file, line: line)
    }

    private func assertSynced(_ result: SyncCycleResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .synced = result else { return XCTFail("Expected sync, got \(result)", file: file, line: line) }
    }
}

private struct PausedManifestRebuild: StoreRebuildServiceProtocol {
    let gate: TestWait.Gate
    func rebuild(fromRoot root: String, context: ModelContext) -> RebuildResult {
        do { try gate.wait() } catch { return RebuildResult(warnings: ["Rebuild gate failed"], storeUnreadable: true) }
        return StoreRebuildService().rebuild(fromRoot: root, context: context)
    }
}

private struct PausedManifestFastForward: FastForwardGitService {
    let wrapped: AllowlistedFastForwardGit
    let gate: TestWait.Gate
    func remoteURL(at path: String) throws -> String? { try wrapped.remoteURL(at: path) }
    func isWorktreeClean(at path: String) -> Bool { wrapped.isWorktreeClean(at: path) }
    func fetch(at path: String, credential: GitCredential?) throws { try wrapped.fetch(at: path, credential: credential) }
    func fastForwardOnly(at path: String, credential: GitCredential?) throws -> FastForwardResult {
        try gate.wait()
        return try wrapped.fastForwardOnly(at: path, credential: credential)
    }
}
