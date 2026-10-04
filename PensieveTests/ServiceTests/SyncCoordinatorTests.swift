import Foundation
import SwiftData
import XCTest
@testable import Pensieve

private typealias CoordinatorCategory = Pensieve.Category

@MainActor
final class SyncCoordinatorTests: XCTestCase {
    private var tempDir = ""

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
        tempDir = base.appendingPathComponent("pensieve-sync-coordinator-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if !tempDir.isEmpty { try? FileManager.default.removeItem(atPath: tempDir) }
    }

    func testScheduledTickIngestsRemoteChange() async throws {
        let harness = try makeRemoteHarness()
        let coordinator = await configuredCoordinator(container: harness.container, engine: harness.engine,
                                                      git: harness.allowlistedGit, root: harness.clone)
        let startupCompleted = expectation(description: "startup cycle")
        let tickCompleted = expectation(description: "tick cycle")
        var cycles = 0
        let scheduler = makeScheduler {
            _ = await coordinator.runCycle()
            cycles += 1
            (cycles == 1 ? startupCompleted : tickCompleted).fulfill()
        }
        scheduler.coordinatorBecameReady()
        scheduler.launchIngestCompleted()
        await fulfillment(of: [startupCompleted], timeout: 5)

        let peer = tempDir + "/peer"
        try harness.git.clone(remote: harness.remote, into: peer, credential: nil)
        let manifest = ManifestService()
        try manifest.write(
            ManifestSnapshot(
                schemaVersion: ManifestService.currentSchemaVersion,
                categories: [CategoryRecord(name: "Remote", projectKeys: [], skillSlugs: [])],
                projects: [], skills: []
            ),
            toRoot: peer
        )
        XCTAssertTrue(try harness.git.stageAllAndCommit(at: peer, message: "remote category"))
        try harness.git.push(at: peer, credential: nil)
        scheduler.tick()
        await fulfillment(of: [tickCompleted], timeout: 5)

        let fresh = ModelContext(harness.container)
        let categories = try fresh.fetch(FetchDescriptor<CoordinatorCategory>())
        XCTAssertEqual(categories.map(\.name), ["Remote"])
    }

    func testNudgePublishesToBareRemote() async throws {
        let harness = try makeRemoteHarness()
        let coordinator = await configuredCoordinator(container: harness.container, engine: harness.engine,
                                                      git: harness.allowlistedGit, root: harness.clone)
        let launched = expectation(description: "launch cycle")
        let nudged = expectation(description: "nudge cycle")
        var cycles = 0
        let scheduler = makeScheduler {
            _ = await coordinator.runCycle()
            cycles += 1
            (cycles == 1 ? launched : nudged).fulfill()
        }
        scheduler.coordinatorBecameReady()
        scheduler.launchIngestCompleted()
        await fulfillment(of: [launched], timeout: 5)
        let originalHead = try rawGitOutput(["--git-dir", harness.remotePath, "rev-parse", "HEAD"])

        let context = ModelContext(harness.container)
        context.insert(CoordinatorCategory(name: "Local"))
        try context.save()
        scheduler.nudge()
        await fulfillment(of: [nudged], timeout: 5)

        let advancedHead = try rawGitOutput(["--git-dir", harness.remotePath, "rev-parse", "HEAD"])
        XCTAssertNotEqual(advancedHead, originalHead)
    }

    func testLockBusyTickSkips() async throws {
        let container = try inMemoryContainer()
        let lockPath = tempDir + "/sync.lock"
        let engine = SyncEngine(lockPath: lockPath)
        let coordinator = await configuredCoordinator(container: container, engine: engine, root: tempDir)
        let startupCompleted = expectation(description: "startup cycle")
        let tickCompleted = expectation(description: "locked tick cycle")
        var cycles = 0
        var result: SyncCycleResult?
        let scheduler = makeScheduler {
            result = await coordinator.runCycle()
            cycles += 1
            (cycles == 1 ? startupCompleted : tickCompleted).fulfill()
        }
        scheduler.coordinatorBecameReady()
        scheduler.launchIngestCompleted()
        await fulfillment(of: [startupCompleted], timeout: 2)

        let held = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
        defer { held.release() }
        scheduler.tick()
        await fulfillment(of: [tickCompleted], timeout: 2)
        XCTAssertEqual(result, .locked)
        XCTAssertFalse(scheduler.isSyncing)
    }

    func testNoRemoteTickSilent() async {
        var cycles = 0
        let scheduler = SyncScheduler(
            debounceSeconds: 0,
            startAutomatically: false,
            backgroundSyncEnabled: { true }
        )
        scheduler.installDrain(hasRemote: { false }, action: { cycles += 1 })
        scheduler.coordinatorBecameReady()
        scheduler.launchIngestCompleted()
        scheduler.tick()
        await Task.yield()
        XCTAssertEqual(cycles, 0)
        XCTAssertFalse(scheduler.hasPendingTrigger)
    }

    func testPreBootstrapTriggerFiresAfterCoordinatorReady() async {
        let fired = expectation(description: "late coordinator drains launch")
        var cycles = 0
        let scheduler = makeScheduler {
            cycles += 1
            fired.fulfill()
        }
        scheduler.tick()
        scheduler.launchIngestCompleted()
        await Task.yield()
        XCTAssertEqual(cycles, 0)
        scheduler.coordinatorBecameReady()
        await fulfillment(of: [fired], timeout: 1)
        XCTAssertEqual(cycles, 1)
    }

    func testConflictedStateSkipsScheduledRun() async {
        var cycles = 0
        let scheduler = SyncScheduler(
            debounceSeconds: 0,
            startAutomatically: false,
            backgroundSyncEnabled: { true }
        )
        scheduler.installDrain(isConflicted: { true }, action: { cycles += 1 })
        scheduler.coordinatorBecameReady()
        scheduler.launchIngestCompleted()
        scheduler.tick()
        await Task.yield()
        XCTAssertEqual(cycles, 0)
        XCTAssertFalse(scheduler.hasPendingTrigger)
    }
}

extension SyncCoordinatorTests {
    func testMainActorHeartbeatDuringBlockedSync() async throws {
        let engine = BlockingEngine()
        let coordinator = await configuredCoordinator(container: try inMemoryContainer(), engine: engine, root: tempDir)
        let cycle = Task.detached {
            _ = await coordinator.runCycle()
        }
        let heartbeat = Task { @MainActor in
            try await Task.sleep(nanoseconds: 20_000_000)
            return Date()
        }
        let beat = try await heartbeat.value
        await cycle.value
        let engineFinished = try XCTUnwrap(engine.finishedAt)
        XCTAssertLessThan(beat, engineFinished, "the main actor heartbeat must advance before the blocking engine returns")
    }

    func testRegisteredObjectFieldChangeVisibleToFreshMainContext() async throws {
        let container = try inMemoryContainer()
        let mainContext = ModelContext(container)
        let category = CoordinatorCategory(name: "Before")
        mainContext.insert(category)
        try mainContext.save()
        let registered = try XCTUnwrap(mainContext.fetch(FetchDescriptor<CoordinatorCategory>()).first)

        let coordinator = await configuredCoordinator(
            container: container,
            engine: CategoryMutatingEngine(newName: "After"),
            root: tempDir
        )
        _ = await coordinator.runCycle()

        let freshContext = ModelContext(container)
        let fresh = try XCTUnwrap(freshContext.fetch(FetchDescriptor<CoordinatorCategory>()).first)
        XCTAssertEqual(fresh.name, "After")
        XCTAssertEqual(registered.name, "Before", "the test must exercise a stale already-registered object")
    }

    func testEachCycleReadsFreshUIContextState() async throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let category = CoordinatorCategory(name: "Before")
        context.insert(category)
        try context.save()
        var retainedContexts: [ModelContext] = []
        var names: [String] = []
        let engine = CategoryMutatingEngine(newName: nil, onRead: { context, category in
            retainedContexts.append(context)
            names.append(category.name)
        })
        let coordinator = await configuredCoordinator(container: container, engine: engine, root: tempDir)
        _ = await coordinator.runCycle()
        category.name = "After"
        try context.save()
        _ = await coordinator.runCycle()
        XCTAssertEqual(names, ["Before", "After"])
        XCTAssertEqual(Set(retainedContexts.map(ObjectIdentifier.init)).count, 2)
    }

    private func makeScheduler(action: @escaping () async -> Void) -> SyncScheduler {
        let scheduler = SyncScheduler(
            debounceSeconds: 0,
            startAutomatically: false,
            backgroundSyncEnabled: { true }
        )
        scheduler.installDrain(action: action)
        return scheduler
    }

    private func inMemoryContainer() throws -> ModelContainer {
        try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func configuredCoordinator(
        container: ModelContainer,
        engine: SyncEngineProtocol,
        git: GitServiceProtocol = GitService(),
        root: String
    ) async -> SyncCoordinator {
        let coordinator = await Task.detached { SyncCoordinator(modelContainer: container) }.value
        await coordinator.configure(
            engine: engine,
            git: git,
            credentials: EmptyCredentialStore(),
            root: root,
            audit: NullAudit(),
            machineIdentity: InertMachineIdentity(),
            machineStateService: InertMachineStateService()
        )
        return coordinator
    }

    private func makeRemoteHarness() throws -> RemoteHarness {
        let remotePath = tempDir + "/remote.git"
        XCTAssertEqual(try rawGit(["init", "--bare", remotePath]), 0)
        let remote = "file://" + remotePath
        let seed = tempDir + "/seed"
        try FileManager.default.createDirectory(atPath: seed, withIntermediateDirectories: true)
        let git = GitService()
        try git.initRepository(at: seed)
        try git.setRemote(remote, at: seed)
        try ManifestService().write(
            ManifestSnapshot(
                schemaVersion: ManifestService.currentSchemaVersion,
                categories: [], projects: [], skills: []
            ),
            toRoot: seed
        )
        try "manifest/categories/*.yaml merge=union\nmanifest/projects.yaml merge=union\n"
            .write(toFile: seed + "/.gitattributes", atomically: true, encoding: .utf8)
        try ".DS_Store\n".write(toFile: seed + "/.gitignore", atomically: true, encoding: .utf8)
        XCTAssertTrue(try git.stageAllAndCommit(at: seed, message: "seed"))
        try git.push(at: seed, credential: nil)
        let clone = tempDir + "/clone"
        try git.clone(remote: remote, into: clone, credential: nil)
        let container = try inMemoryContainer()
        let allowlisted = AllowlistedRemoteGit(wrapping: git)
        let engine = SyncEngine(
            gitService: allowlisted,
            manifestService: ManifestService(),
            storeRebuildService: StoreRebuildService(),
            fileService: FileService(),
            lockPath: tempDir + "/engine.lock"
        )
        return RemoteHarness(remotePath: remotePath, remote: remote, clone: clone, git: git,
                             allowlistedGit: allowlisted, engine: engine, container: container)
    }

    private func rawGit(_ args: [String]) throws -> Int32 {
        try rawGitRun(args).status
    }

    private func rawGitRun(_ args: [String]) throws -> (status: Int32, data: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        try process.run()
        let data = sink.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
    private func rawGitOutput(_ args: [String]) throws -> String {
        let result = try rawGitRun(args)
        XCTAssertEqual(result.status, 0)
        return (String(bytes: result.data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
private struct RemoteHarness {
    let remotePath, remote, clone: String
    let git: GitService
    let allowlistedGit: AllowlistedRemoteGit
    let engine: SyncEngine
    let container: ModelContainer
}
private struct EmptyCredentialStore: CredentialStoreProtocol {
    func credential(forHost host: String) -> GitCredential? { nil }
    func store(token: String, username: String, forHost host: String) throws {}
    func delete(forHost host: String) throws {}
}
private struct NullAudit: SyncAuditWriting {
    func record(category: String, detail: String) {}
}
private final class BlockingEngine: SyncEngineProtocol, @unchecked Sendable {
    private let stateLock = NSLock()
    private var recordedFinishedAt: Date?
    var finishedAt: Date? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordedFinishedAt
    }
    func sync(root: String, message: String, credential: GitCredential?, context: ModelContext,
              prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome {
        try prepare?(context)
        Thread.sleep(forTimeInterval: 0.3)
        stateLock.lock()
        recordedFinishedAt = Date()
        stateLock.unlock()
        return .synced(pushed: false, warnings: [])
    }
    func inspectConflicts(root: String, credential: GitCredential?, context: ModelContext) throws -> ConflictInspection {
        fatalError("unused")
    }
    func resolveConflicts(root: String, picks: [String: ResolutionPick], credential: GitCredential?,
                          context: ModelContext) throws -> SyncOutcome {
        fatalError("unused")
    }
}
private struct CategoryMutatingEngine: SyncEngineProtocol {
    let newName: String?
    var onRead: (ModelContext, CoordinatorCategory) -> Void = { _, _ in }
    func sync(root: String, message: String, credential: GitCredential?, context: ModelContext,
              prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome {
        try prepare?(context)
        let category = try XCTUnwrap(context.fetch(FetchDescriptor<CoordinatorCategory>()).first)
        onRead(context, category)
        if let newName {
            category.name = newName
            try context.save()
        }
        return .synced(pushed: false, warnings: [])
    }
    func inspectConflicts(root: String, credential: GitCredential?, context: ModelContext) throws -> ConflictInspection {
        fatalError("unused")
    }
    func resolveConflicts(root: String, picks: [String: ResolutionPick], credential: GitCredential?,
                          context: ModelContext) throws -> SyncOutcome {
        fatalError("unused")
    }
}
actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
