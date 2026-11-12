import SwiftData
import XCTest
@testable import Pensieve

/// Real disk, queue, rebuild and deployment boundaries; only agent discovery is fixed.
@MainActor
final class SkillRenameTakeoverFixture {
    private let directory = TestStoreDirectory(named: "rename-takeover")
    let files = FileService()
    let manifest: ManifestService
    let context: ModelContext
    let skill = Skill(name: "Alpha", tags: ["own"], scope: .project, directoryName: "alpha")
    let other = Skill(name: "Other", directoryName: "other")
    let ownCategory = Pensieve.Category(name: "Own")
    let goneCategory = Pensieve.Category(name: "Gone")
    let projects: [Project]
    let store: SkillStore
    let saves: ManifestSaveModel
    let library: SkillLibraryViewModel
    let tagLibrary: SkillLibraryViewModel
    let platform: PlatformViewModel
    let local: String
    let peer = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    let own: SkillOverlay
    let leftover: SkillOverlay
    var root: String { directory.storeRoot }
    var lockPath: String { directory.root + "/support/sync.lock" }

    init(record: Bool = true, leftovers: Bool = true,
         writeLockAttempted: @escaping (Bool) -> Void = { _ in }) throws {
        manifest = ManifestService(writeLockAttempted: writeLockAttempted)
        let parent = directory.root
        let root = directory.storeRoot, support = parent + "/support"
        context = ModelContext(try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
        context.autosaveEnabled = false
        store = SkillStore(fileService: files, baseDir: root + "/skills", storeRoot: root)
        local = try MachineIdentity(fileService: files, appSupportDir: support).identifier()
        skill.createdAt = Date(timeIntervalSince1970: 1_700_000_000.123)
        for row in [skill, other] {
            context.insert(row)
            _ = try store.createSkill(name: row.name, description: "Job", body: "Own body.")
        }
        let modelContext = context, fileService = files
        projects = try ["own", "gone"].map { name in
            let row = Project(name: name, path: parent + "/" + name)
            row.identityKey = "github.com/owner/" + name
            row.identityKind = "git"
            try fileService.createDirectory(at: row.path)
            modelContext.insert(row)
            return row
        }
        try Self.seedAssignments(context: context, categories: [ownCategory, goneCategory],
            machines: [local, peer], leftovers: leftovers)
        var snapshot = try manifest.snapshot(from: context)
        own = try XCTUnwrap(snapshot.skills.first { $0.slug == "alpha" })
        var gone = own; gone.slug = "zulu"; gone.tags = ["gone"]; gone.scope = .user
        gone.createdAt = Date(timeIntervalSince1970: 1_600_000_000.456)
        leftover = gone
        if record { snapshot.skills.append(gone) }
        try manifest.write(snapshot, toRoot: root)
        saves = ManifestSaveModel(manifest: manifest, root: root, lockPath: support + "/sync.lock",
            waitSeconds: 0.01, files: files)
        library = SkillLibraryViewModel(skillStore: store, fileService: files,
            fileWatchService: RecordingWatcher(), manifestRoot: root,
            notifier: SyncStateNotifier.suppressed, manifestSaves: saves)
        tagLibrary = SkillLibraryViewModel(skillStore: store, fileService: files,
            fileWatchService: RecordingWatcher(), manifestRoot: root,
            notifier: SyncStateNotifier.suppressed, manifestSaves: saves)
        let paths = DeployPaths(skillsDirectory: store.baseDir,
            userSkillsDirectories: [.claudeCode: directory.root + "/agent"],
            cursorUserRulesDirectory: directory.root + "/rules")
        platform = PlatformViewModel(fileService: files, linkService: LinkService(fileService: files, paths: paths),
            cursorCompiler: CursorCompiler(fileService: files, skillStore: store,
                userRulesDirectory: paths.cursorUserRulesDirectory),
            agentDetection: DeletionTestDetection(installed: [.claudeCode, .cursor]),
            deployStateStore: DeployStateStore(fileService: files, appSupportDir: support), skillsDirectory: store.baseDir)
        let batch = CategoryReconciler(platformVM: platform).reconcileDeployments(context: context)
        XCTAssertFalse(batch.hasFailures)
    }

    private static func seedAssignments(context: ModelContext, categories: [Pensieve.Category],
                                        machines: [String], leftovers: Bool) throws {
        categories[0].skillSlugs = ["alpha"]
        categories[0].projectKeys = ["github.com/owner/own"]
        categories[1].skillSlugs = leftovers ? ["zulu"] : []
        categories[1].projectKeys = ["github.com/owner/gone"]
        for category in categories { context.insert(category) }
        for (slug, project) in [("alpha", "own"), ("zulu", "gone")] where slug == "alpha" || leftovers {
            for machine in machines {
                context.insert(MachineDeployIntent(machineID: machine, skillSlug: slug,
                    platformRaw: PlatformTarget.claudeCode.rawValue, projectKey: "github.com/owner/" + project))
            }
        }
        try context.save()
    }

    func cleanup() { try? files.deleteDirectory(at: directory.root) }

    func rename(persist: (ModelContext) throws -> Void = { try $0.save() }) -> Bool {
        SkillRenameFlow.rename(skill: skill, to: "Zulu", library: library, platformVM: platform,
            projects: projects, context: context, persist: persist)
    }

    func arrivePeer(removingOld: Bool = false) throws {
        var disk = try manifest.read(fromRoot: root)
        disk.skills.removeAll { $0.slug == "zulu" || (removingOld && $0.slug == "alpha") }
        var arrived = leftover
        arrived.createdAt = Date(timeIntervalSince1970: 1_650_000_000)
        disk.skills.append(arrived)
        if let index = disk.categories.firstIndex(where: { $0.name == "Gone" }) {
            disk.categories[index].skillSlugs = ["zulu"]
        }
        disk.deployIntents.removeAll { $0.skillSlug == "zulu" }
        disk.deployIntents += [local, peer].map {
            DeployIntentRecord(machineID: $0, skillSlug: "zulu", platformRaw: PlatformTarget.claudeCode.rawValue,
                projectKey: "github.com/owner/gone")
        }
        try manifest.write(disk, toRoot: root)
    }

    func moveHead() throws {
        let root = root
        try NativeTestWork.run {
            try TestPaths.git.initRepository(at: root)
            XCTAssertTrue(try TestPaths.git.stageAllAndCommit(at: root, message: "pulled library"))
        }
    }

    func takenMessage() -> String {
        "The name “zulu” is taken by a skill on another Mac, so this rename wasn't saved to the synced library."
    }

    func assertOwn(_ snapshot: ManifestSnapshot, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(snapshot.skills.contains { $0.slug == "alpha" }, file: file, line: line)
        var expected = own; expected.slug = "zulu"
        XCTAssertEqual(snapshot.skills.first { $0.slug == "zulu" }, expected, file: file, line: line)
        XCTAssertEqual(snapshot.skills.filter { $0.slug == "zulu" }.count, 1, file: file, line: line)
        XCTAssertEqual(snapshot.categories.first { $0.name == "Own" }?.skillSlugs, ["zulu"], file: file, line: line)
        XCTAssertEqual(snapshot.categories.first { $0.name == "Gone" }?.skillSlugs, [], file: file, line: line)
        let requests = [local, peer].map {
            DeployIntentRecord(machineID: $0, skillSlug: "zulu", platformRaw: PlatformTarget.claudeCode.rawValue,
                projectKey: "github.com/owner/own")
        }
        XCTAssertEqual(snapshot.deployIntents.sorted { $0.machineID < $1.machineID },
            requests.sorted { $0.machineID < $1.machineID }, file: file, line: line)
    }

    func assertWindow(file: StaticString = #filePath, line: UInt = #line) throws {
        try assertOwn(manifest.snapshot(from: context), file: file, line: line)
        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first { $0.directoryName == "zulu" })
        XCTAssertTrue(row === skill, file: file, line: line)
        XCTAssertEqual(row.id, skill.id, file: file, line: line)
        for (index, project) in projects.enumerated() {
            let link = project.path + "/.claude/skills/zulu"
            let rule = project.path + "/.cursor/rules/zulu.mdc"
            if index == 0 {
                XCTAssertEqual(try files.symlinkTarget(at: link), store.baseDir + "/zulu", file: file, line: line)
            } else {
                XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: link), file: file, line: line)
                XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: rule), file: file, line: line)
            }
        }
    }

    func assertFreshRebuild() throws {
        let fresh = ModelContext(try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
        let result = StoreRebuildService(fileService: files, manifestService: manifest).rebuild(fromRoot: root, context: fresh)
        XCTAssertFalse(result.ingestIncomplete)
        try assertOwn(manifest.snapshot(from: fresh))
    }
}
