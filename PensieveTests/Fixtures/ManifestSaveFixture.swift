import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ManifestSaveFixture {
    final class Messages { var lines: [String] = [] }
    private let directory = TestStoreDirectory(named: "manifest-save")
    let root: String
    let lockPath: String
    let files = FileService()
    let manifest = ManifestService()
    var currentContext: ModelContext?
    var context: ModelContext { currentContext! }
    var currentSaves: ManifestSaveModel?
    var saves: ManifestSaveModel { currentSaves! }
    let recording = RecordingSaveManifest()
    let messages = Messages()
    var currentLibrary: SkillLibraryViewModel?
    var library: SkillLibraryViewModel { currentLibrary! }
    var currentCategories: CategoryStore?
    var categories: CategoryStore { currentCategories! }
    let platform: PlatformViewModel
    var currentLocal: Pensieve.Category? = Pensieve.Category(name: "Local")
    var local: Pensieve.Category { currentLocal! }
    var currentDoomed: Pensieve.Category? = Pensieve.Category(name: "ZDelete")
    var doomed: Pensieve.Category { currentDoomed! }
    var currentAlpha: Skill? = Skill(name: "Alpha", directoryName: "alpha")
    var alpha: Skill { currentAlpha! }
    var currentBeta: Skill? = Skill(name: "Beta", directoryName: "beta")
    var beta: Skill { currentBeta! }
    var currentProject: Project?
    var project: Project { currentProject! }

    let persistent: Bool
    var runtime: AppRuntime?
    var recordPath: String { RuntimePaths(storeRoot: root, appSupportDir: root + "/support").refusedCreatesPath }
    var storeURL: URL { URL(fileURLWithPath: directory.root + "/library.store") }

    init(unopenableLock: Bool = false, waitSeconds: TimeInterval = 0.01,
         rebuildFiles: FileServiceProtocol? = nil, failAlphaDeletion: Bool = false, persistent: Bool = false) throws {
        self.persistent = persistent
        root = directory.storeRoot
        lockPath = root + "/support/sync.lock"
        platform = PlatformViewModel(fileService: files, linkService: DeletionTestLinkService(),
            cursorCompiler: DeletionTestCursorCompiler(), agentDetection: DeletionTestDetection(installed: []),
            deployStateStore: .memoryBacked, skillsDirectory: root + "/skills")
        currentContext = ModelContext(try AppRuntime.makeContainer(configuration: persistent
            ? ModelConfiguration(url: URL(fileURLWithPath: directory.root + "/library.store"))
            : ModelConfiguration(isStoredInMemoryOnly: true)))
        recording.base = ManifestService(fileService: rebuildFiles ?? files)
        let messages = messages
        currentSaves = ManifestSaveModel(manifest: recording, root: root, lockPath: lockPath,
            refusedCreatesPath: persistent
                ? RuntimePaths(storeRoot: root, appSupportDir: root + "/support").refusedCreatesPath : nil,
            waitSeconds: waitSeconds, files: rebuildFiles ?? files, log: { messages.lines.append($0) })
        let skillFiles: FileServiceProtocol = failAlphaDeletion
            ? FaultyFileService(wrapped: files, failDeletePath: root + "/skills/alpha") : files
        currentLibrary = SkillLibraryViewModel(skillStore: SkillStore(fileService: skillFiles,
            baseDir: root + "/skills", storeRoot: root),
            fileWatchService: FileWatchService(rootDir: root + "/skills"),
            manifestRoot: root, manifestSaves: saves)
        currentCategories = CategoryStore( manifestSaves: saves)
        currentProject = Project(name: "Local", path: root + "/project")
        project.identityKey = "local-key"
        for skill in [alpha, beta] {
            skill.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
            context.insert(skill)
            try files.writeFile(at: skill.canonicalPath(skillsDirectory: root + "/skills"),
                content: SkillSerializer.serialize(name: skill.name, description: "description", body: "body"))
        }
        context.insert(local)
        context.insert(doomed)
        context.insert(project)
        try context.save()
        try manifest.write(try manifest.snapshot(from: context), toRoot: root)
        if unopenableLock { try files.createDirectory(at: lockPath) }
    }

    func manifestBytes() throws -> [String: Data] {
        try Self.manifestBytes(root: root, files: files)
    }

    func assertWaitingBehindHeldLock(pending: Int, before: [String: Data],
                                     file: StaticString = #filePath, line: UInt = #line) async {
        await TestWait.until(failureMessage: "The queued saves never reached their lock wait or completion") {
            self.saves.isWaiting || self.saves.pendingCount == 0
        }
        XCTAssertTrue(saves.isWaiting, "Saves must wait for the held sync.lock", file: file, line: line)
        XCTAssertEqual(saves.pendingCount, pending, file: file, line: line)
        XCTAssertTrue(recording.writes.isEmpty, "No queued writer may publish through the held lock", file: file, line: line)
        XCTAssertEqual(try manifestBytes(), before, file: file, line: line)
    }

    static func manifestBytes(root: String, files: FileServiceProtocol) throws -> [String: Data] {
        var result: [String: Data] = [:]
        func walk(_ relative: String) throws {
            for name in try files.listDirectory(at: root + "/manifest" + relative) {
                let path = relative + "/" + name
                if files.directoryExists(at: root + "/manifest" + path) { try walk(path) } else {
                    result[path] = try files.readData(at: root + "/manifest" + path)
                }
            }
        }
        try walk("")
        return result
    }

    func cleanup() {
        quit()
        try? files.deleteDirectory(at: directory.root)
    }
}

/// Records the real full-snapshot writes, preserving their thread order; it does not implement merging.
final class RecordingSaveManifest: ManifestSnapshotting {
    var base = ManifestService()
    var afterRead: (() throws -> Void)?
    var afterReadFailure: (() throws -> Void)?
    private let lock = NSLock()
    private var snapshots: [ManifestSnapshot] = []
    var failingWrites = 0
    var failingSnapshots = 0
    var failingRebuildSnapshots = 0
    /// Category order is not a snapshot contract. Force a valid peer-first order when testing
    /// pending rename collisions, rather than relying on ModelContext's unsorted fetch order.
    var sortRebuildCategories = false
    var beforeWrite: (() throws -> Void)?
    var afterWrite: (() -> Void)?
    var afterRebuildSnapshot: (() throws -> Void)?
    struct Refused: LocalizedError { var errorDescription: String? { "The local library could not be read." } }
    var writes: [ManifestSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots
    }
    func snapshot(from context: ModelContext) throws -> ManifestSnapshot {
        if !Thread.isMainThread, failingRebuildSnapshots > 0 {
            failingRebuildSnapshots -= 1
            throw CocoaError(.fileReadCorruptFile)
        }
        // These faults belong to the window fallback/projection read, not the worker result read.
        if Thread.isMainThread, failingSnapshots > 0 { failingSnapshots -= 1; throw Refused() }
        var value = try base.snapshot(from: context)
        if !Thread.isMainThread, sortRebuildCategories { value.categories.sort { $0.name < $1.name } }
        if !Thread.isMainThread { try afterRebuildSnapshot?() }
        return value
    }
    func read(fromRoot root: String) throws -> ManifestSnapshot {
        do {
            let value = try base.read(fromRoot: root)
            try afterRead?()
            return value
        } catch {
            try afterReadFailure?()
            throw error
        }
    }
    func repair(_ snapshot: ManifestSnapshot, root: String, replacing damage: ManifestDamage) throws -> Bool {
        try base.repair(snapshot, root: root, replacing: damage)
    }
    func write(_ snapshot: ManifestSnapshot, toRoot root: String) throws {
        if failingWrites > 0 { failingWrites -= 1; throw CocoaError(.fileWriteNoPermission) }
        try beforeWrite?()
        try base.write(snapshot, toRoot: root)
        lock.lock()
        snapshots.append(snapshot)
        lock.unlock()
        afterWrite?()
    }
}

/// Two independent creates meet only at publication. All folders and Git remotes live in this
/// fixture's temporary parent; the peer contributes metadata, never a manufactured skill folder.
@MainActor
final class CollisionCreateFixture {
    let f: IncompleteIngestFixture
    var context: ModelContext!
    var recording = RecordingSaveManifest()
    var saves: ManifestSaveModel!
    var library: SkillLibraryViewModel!
    var skill: Skill!
    let local: SkillOverlay
    var peer: ManifestSnapshot
    let platform: PlatformViewModel
    let support: String

    var runtime: AppRuntime?
    let persistent: Bool
    let failDelete: Bool
    var logs: [String] = []
    var recordPath: String { RuntimePaths(storeRoot: f.app, appSupportDir: support).refusedCreatesPath }
    var storeURL: URL { URL(fileURLWithPath: f.base + "/library.store") }

    static func writtenDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func message(_ slug: String) -> String {
        "Another Mac already has a skill named “\(slug)”. Rename this skill to keep its tags and scope; "
            + "they aren't saved until you do."
    }

    init(committed: Bool = false, unreadable: Bool = false, failDelete: Bool = false,
         persistent: Bool = false, noPeer: Bool = false) throws {
        self.persistent = persistent; self.failDelete = failDelete
        let base = TestTemporaryDirectory.url.appendingPathComponent(UUID().uuidString).path
        f = try NativeTestWork.run { try IncompleteIngestFixture(base: base) }
        support = base + "/support"
        let container = try Self.makeContainer(base: base, persistent: persistent)
        try NativeTestWork.run(container: container) { worker in
            _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: base + "/app", context: worker)
        }
        context = ModelContext(container)
        for row in try context.fetch(FetchDescriptor<Skill>()) { context.delete(row) }
        try context.save()
        try f.files.deleteDirectory(at: f.app + "/skills/item")
        let files = FaultyFileService(wrapped: f.files,
            failDeletePath: failDelete ? f.app + "/skills/item" : nil)
        saves = ManifestSaveModel(manifest: recording, root: f.app, lockPath: base + "/sync.lock",
            refusedCreatesPath: persistent ? RuntimePaths(storeRoot: f.app, appSupportDir: support).refusedCreatesPath : nil)
        library = SkillLibraryViewModel(skillStore: SkillStore(fileService: files, baseDir: f.app + "/skills", storeRoot: f.app),
            fileWatchService: RecordingWatcher(), manifestRoot: f.app, manifestSaves: saves)
        // The worker cannot run on the main actor until init returns, so the peer arrives after
        // the local folder and row exist, but before the queue reads the manifest.
        skill = try XCTUnwrap(library.createSkill(name: "Item", description: "Local job", body: "local body",
            tags: ["local"], context: context))
        local = try XCTUnwrap(f.manifest.snapshot(from: context).skills.first)
        var remote = local
        remote.createdAt = Date(timeIntervalSince1970: 1_600_000_000.321)
        remote.tags = ["peer"]
        remote.scope = .project
        remote.origin = .imported(from: "cursor")
        peer = try f.manifest.read(fromRoot: f.app)
        peer.skills = noPeer ? [] : [remote]
        peer.categories[0].skillSlugs = noPeer ? [] : ["item"]
        peer.deployIntents = noPeer ? [] : [DeployIntentRecord(machineID: ProjectIntentHarness.remoteID, skillSlug: "item",
            platformRaw: PlatformTarget.claudeCode.rawValue, projectKey: nil)]
        try f.manifest.write(peer, toRoot: committed ? f.peer : f.app)
        if committed {
            let f = f
            try NativeTestWork.run {
                _ = try f.git.stageAllAndCommit(at: f.peer, message: "peer create")
                try f.git.push(at: f.peer, credential: nil)
                _ = try f.git.fastForwardOnly(at: f.app, credential: nil)
            }
        }
        recording.failingSnapshots = unreadable ? .max : 0
        recording.failingWrites = noPeer ? 1 : 0
        try f.files.writeFile(at: support + "/machine-id", content: ProjectIntentHarness.localID)
        let paths = DeployPaths(skillsDirectory: f.app + "/skills", userSkillsDirectories: [:],
            cursorUserRulesDirectory: base + "/cursor")
        platform = PlatformViewModel(fileService: f.files, linkService: LinkService(fileService: f.files, paths: paths),
            cursorCompiler: CursorCompiler(fileService: f.files, skillStore: library.skillStore,
                userRulesDirectory: base + "/cursor"),
            agentDetection: DeletionTestDetection(installed: []),
            deployStateStore: DeployStateStore(fileService: f.files, appSupportDir: support), skillsDirectory: f.app + "/skills")
    }

    private static func makeContainer(base: String, persistent: Bool) throws -> ModelContainer {
        try AppRuntime.makeContainer(configuration: persistent
            ? ModelConfiguration(url: URL(fileURLWithPath: base + "/library.store"))
            : ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func cleanup() {
        quit()
        try? f.files.deleteDirectory(at: f.base)
    }

    /// A new container has fresh ingest state, just as a new process does. Release the previous
    /// window and its refused edits before opening it; the persistent rows are the only local truth.
    func quit() {
        runtime?.commandServer?.stop()
        library?.stopWatching()
        runtime = nil
        skill = nil
        library = nil
        saves = nil
        context = nil
    }

    func relaunchThroughRuntime() async throws {
        precondition(persistent)
        quit()
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(url: storeURL))
        let paths = AppRuntimePaths(storeRoot: f.app, appSupportDir: support)
        let defaults = try paths.makeDefaults()
        defaults.set(false, forKey: AppRuntime.backgroundSyncEnabledKey)
        // The fixture represents a Mac that already created a skill in an established library.
        defaults.set(true, forKey: AppRuntime.migrationDefaultsKey)
        let runtime = try AppRuntime(container: container,
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            defaults: defaults, launchBackfill: { _ in },
            paths: paths, updateCheckOperation: { _ in RuntimeUpdateCheckResult(report: UpdateCheckReport(), skills: [:]) },
            gitUsabilityProbe: { .usable }, coordinatorConfigure: { coordinator in
                await coordinator.configure(engine: RecoveredPresentationEngine(), git: paths.makeGitService(),
                    credentials: InMemoryCredentialStore(), root: paths.storeRoot,
                    audit: SyncAudit(appSupport: paths.appSupportDir),
                    machine: (identity: InertMachineIdentity(), stateService: InertMachineStateService()))
            })
        self.runtime = runtime
        context = container.mainContext
        library = runtime.library
        saves = try XCTUnwrap(library.manifestSaves)
        await runtime.performLaunchWorkIfNeeded(context: context)
        library.stopWatching()
        skill = try context.fetch(FetchDescriptor<Skill>()).first
    }

    func relaunch(failingSnapshots: Int = 0, afterManifestRead: (() throws -> Void)? = nil) throws {
        precondition(persistent)
        quit()
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(url: storeURL))
        context = ModelContext(container)
        recording = RecordingSaveManifest()
        recording.failingSnapshots = failingSnapshots
        recording.afterRead = afterManifestRead
        saves = ManifestSaveModel(manifest: recording, root: f.app, lockPath: support + "/sync.lock",
            refusedCreatesPath: recordPath, log: { [weak self] in self?.logs.append($0) })
        let files = FaultyFileService(wrapped: f.files, failDeletePath: failDelete ? f.app + "/skills/item" : nil)
        library = SkillLibraryViewModel(skillStore: SkillStore(fileService: files, baseDir: f.app + "/skills", storeRoot: f.app),
            fileWatchService: RecordingWatcher(), manifestRoot: f.app, manifestSaves: saves)
        saves.restoreRefusedCreates(context: context)
        let f = f
        try NativeTestWork.run(container: container) { worker in
            _ = StoreRebuildService().rebuild(fromRoot: f.app, context: worker)
        }
        skill = try context.fetch(FetchDescriptor<Skill>()).first
    }

    func record() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: f.files.readData(at: recordPath)) as? [String: Any])
    }

    func held() throws -> [[String: Any]] { try XCTUnwrap(record()["held"] as? [[String: Any]]) }
    func heldSlugs() throws -> [String] { try held().compactMap { $0["slug"] as? String }.sorted() }
    func preserved() throws -> [String] { try XCTUnwrap(record()["preserved"] as? [String]).sorted() }

    func writeRecord(held: [[String: Any]], preserved: [String] = [], version: Int = 1) throws {
        let bytes = try JSONSerialization.data(withJSONObject: ["schema_version": version, "held": held, "preserved": preserved],
            options: [.sortedKeys])
        try f.files.writeFile(at: recordPath, content: try XCTUnwrap(String(data: bytes, encoding: .utf8)))
    }

    func addOwnIntent() throws {
        context.insert(MachineDeployIntent(machineID: ProjectIntentHarness.localID, skillSlug: "item",
            platformRaw: PlatformTarget.claudeCode.rawValue))
        try context.save()
    }

    func ownIntents() throws -> [String] {
        try context.fetch(FetchDescriptor<MachineDeployIntent>()).filter { $0.machineID == ProjectIntentHarness.localID }
            .map(\.skillSlug).sorted()
    }

    func assertPeer(file: StaticString = #filePath, line: UInt = #line) throws {
        let durable = try f.manifest.read(fromRoot: f.app)
        XCTAssertEqual(durable.skills.first { $0.slug == "item" }, peer.skills[0], file: file, line: line)
        XCTAssertTrue(durable.deployIntents.contains(peer.deployIntents[0]), file: file, line: line)
        XCTAssertEqual(durable.categories, peer.categories, file: file, line: line)
    }

    func assertLocal(slug: String = "item", tags: [String]? = nil, scope: SkillScope? = nil,
                     file: StaticString = #filePath, line: UInt = #line) throws {
        let current = try XCTUnwrap(f.manifest.snapshot(from: context).skills.first { $0.slug == slug }, file: file, line: line)
        XCTAssertEqual(current.tags, tags ?? local.tags, file: file, line: line)
        XCTAssertEqual(current.scope, scope ?? local.scope, file: file, line: line)
        XCTAssertEqual(current.origin, local.origin, file: file, line: line)
        if persistent {
            XCTAssertEqual(Self.writtenDate(current.createdAt), Self.writtenDate(local.createdAt), file: file, line: line)
        } else {
            XCTAssertEqual(current.createdAt, local.createdAt, file: file, line: line)
        }
    }

    func sync() throws {
        let f = f
        try NativeTestWork.run(container: context.container) { worker in
            guard case .synced = try f.engine(rebuild: StoreRebuildService()).sync(root: f.app,
                message: "publish window", credential: nil, context: worker) else { return XCTFail("Sync must publish") }
        }
    }

    func rebuild() throws {
        _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: f.app, context: context)
    }

    func rename(_ slug: String) -> Bool {
        SkillRenameFlow.rename(skill: skill, to: slug, library: library, platformVM: platform, projects: [], context: context)
    }
}
