import Foundation
import SwiftData
import XCTest
@testable import Pensieve

/// Real deployment and production convergence over isolated disk roots. Reopening releases every
/// context and collaborator before opening the same SwiftData file; no retry state crosses in memory.
@MainActor
final class RemoteRemovalFixture {
    static let agents: [PlatformTarget] = [.claudeCode, .codex, .cursor]
    let root: String
    let paths: AppRuntimePaths
    let files = FileService()
    let manifest: ManifestService
    let store: SkillStore
    let state: DeployStateStore
    private let persistent: Bool
    private var session: RemoteRemovalSession?

    var context: ModelContext { session!.context } // Fixture always has an open session outside reopen().
    var platform: PlatformViewModel { session!.platform }
    var convergence: PostSyncConvergence { session!.convergence }

    init(skills: [String] = ["alpha"], persistent: Bool = false) throws {
        root = TestTemporaryDirectory.path + "RemoteRemoval-" + UUID().uuidString
        paths = AppRuntimePaths(storeRoot: root + "/store", appSupportDir: root + "/support")
        self.persistent = persistent
        manifest = ManifestService(fileService: files)
        store = SkillStore(fileService: files, baseDir: paths.skillsDir, storeRoot: paths.storeRoot)
        state = DeployStateStore(fileService: files, appSupportDir: paths.appSupportDir)
        for slug in skills { _ = try store.createSkill(name: slug, description: "Job for " + slug, body: "Body of " + slug) }
        try files.writeFile(at: paths.appSupportDir + "/machine-id", content: ProjectIntentHarness.localID)
        try reopen()
        for slug in skills { context.insert(Skill(name: slug, directoryName: slug)) }
        try context.save()
    }

    func cleanup() { session = nil; try? files.deleteDirectory(at: root) }

    func reopen() throws {
        session = nil
        let config = persistent ? ModelConfiguration(url: URL(fileURLWithPath: root + "/local.store"))
            : ModelConfiguration(isStoredInMemoryOnly: true)
        session = try RemoteRemovalSession(paths: paths, configuration: config, files: files, store: store, state: state)
    }

    func project(_ name: String, keyed: Bool = true) throws -> Project {
        let project = Project(name: name, path: root + "/" + name)
        try files.createDirectory(at: project.path)
        if keyed {
            let key = "github.com/owner/" + name
            project.identityKey = key
            project.identityKind = "remote"
            try files.writeFile(at: project.path + "/.git/config", content: "[remote \"origin\"]\nurl = https://\(key).git\n")
        }
        context.insert(project)
        try context.save()
        return project
    }

    func skill(_ slug: String = "alpha") throws -> Skill {
        try XCTUnwrap(context.fetch(FetchDescriptor<Skill>()).first { $0.directoryName == slug })
    }

    func intent(_ slug: String = "alpha", project: Project? = nil,
                agents: [PlatformTarget] = RemoteRemovalFixture.agents) {
        for agent in agents {
            context.insert(MachineDeployIntent(machineID: ProjectIntentHarness.localID, skillSlug: slug,
                platformRaw: agent.rawValue, projectKey: project?.identityKey))
        }
    }

    func category(project: Project) throws {
        let category = Pensieve.Category(name: "Tools")
        category.skillSlugs = ["alpha"]
        category.projectKeys = [try XCTUnwrap(project.identityKey)]
        context.insert(category)
    }

    func deployBefore() throws {
        try context.save()
        try manifest.write(try manifest.snapshot(from: context), toRoot: paths.storeRoot)
        try rebuild()
        convergence.runAfterLaunchIngest()
    }

    func direct(project: Project, agents: [PlatformTarget]) throws {
        for agent in agents {
            platform.deploy(skill: try skill(), platform: agent, target: .project(project), context: context)
            XCTAssertNil(platform.error)
        }
    }

    func artifact(_ agent: PlatformTarget, project: String? = nil, slug: String = "alpha") -> String {
        let projectPath = project.map { root + "/" + $0 }
        return agent == .cursor ? paths.deployPaths.cursorPath(directoryName: slug, projectPath: projectPath)
            : paths.deployPaths.linkPath(directoryName: slug, platform: agent, projectPath: projectPath)
    }

    enum Ledger { case intent, category, direct }

    func assertBefore(_ agents: [PlatformTarget] = RemoteRemovalFixture.agents,
                      project: Project? = nil, slug: String = "alpha", ledger: Ledger = .intent) throws {
        let skillID = try skill(slug).id
        let history = try context.fetch(FetchDescriptor<DeployRecord>())
        let intents = try context.fetch(FetchDescriptor<IntentAssignment>())
        let categories = try context.fetch(FetchDescriptor<SkillProjectAssignment>())
        for agent in agents {
            let path = artifact(agent, project: project?.name, slug: slug)
            XCTAssertTrue(try files.entryExistsWithoutFollowingLinks(at: path), path)
            XCTAssertTrue(history.contains { $0.skillID == skillID && $0.targetPath == path }, path)
            XCTAssertTrue(try state.read().records.contains { $0.artifactPath == path }, path)
            let intent = intents.contains {
                $0.skillID == skillID && $0.projectID == project?.id && $0.platformRaw == agent.rawValue
            }
            let category = categories.contains { $0.skillID == skillID && $0.projectID == project?.id && $0.platform == agent }
            XCTAssertEqual(intent, ledger == .intent, path)
            XCTAssertEqual(category, ledger == .category, path)
        }
    }

    func pull(rename: Bool = false) throws {
        if rename { try store.renameSkill(directoryName: "alpha", to: "beta-two") } else {
            try store.deleteSkill(directoryName: "alpha")
        }
        var snapshot = try manifest.read(fromRoot: paths.storeRoot)
        XCTAssertTrue((rename ? ManifestChange.renameSkill("alpha", "beta-two") : .retireSkill("alpha")).apply(to: &snapshot))
        try manifest.write(snapshot, toRoot: paths.storeRoot)
    }

    func rebuild() throws {
        let result = StoreRebuildService(fileService: files, manifestService: manifest)
            .rebuild(fromRoot: paths.storeRoot, context: context)
        XCTAssertFalse(result.ingestIncomplete, result.warnings.joined(separator: "; "))
    }

    func sync() throws {
        try rebuild()
        convergence.run(after: .synced(pushed: false, warnings: [], completedAt: Date(), headAdvanced: true))
    }

    func launch(beforeConvergence: () throws -> Void = {}) throws {
        try rebuild()
        paths.makeLaunchBackfill()(context)
        try beforeConvergence()
        convergence.runAfterLaunchIngest()
    }

    func history(_ id: UUID) throws -> [DeployRecord] {
        try ModelContext(context.container).fetch(FetchDescriptor<DeployRecord>()).filter { $0.skillID == id }
    }

    func assertSettled(_ id: UUID) throws {
        let fresh = ModelContext(context.container)
        XCTAssertFalse(try fresh.fetch(FetchDescriptor<DeployRecord>()).contains { $0.skillID == id })
        XCTAssertFalse(try fresh.fetch(FetchDescriptor<IntentAssignment>()).contains { $0.skillID == id })
        XCTAssertFalse(try fresh.fetch(FetchDescriptor<SkillProjectAssignment>()).contains { $0.skillID == id })
        XCTAssertFalse(try state.read().records.contains { $0.slug == "alpha" })
        try assertNoWaiting()
    }

    func assertNoWaiting() throws {
        XCTAssertTrue(try WaitingRemovalStore(fileService: files, appSupportDir: paths.appSupportDir).read().isEmpty)
    }

    func assertAbsent(_ agents: [PlatformTarget], project: String? = nil) throws {
        for agent in agents {
            let path = artifact(agent, project: project)
            XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: path), path)
        }
    }

    func disk(_ roots: [String]) throws -> [String: String] {
        var entries: [String: String] = [:]
        func visit(_ path: String) throws {
            guard let type = try files.entryTypeWithoutFollowingLinks(at: path) else { return }
            switch type {
            case .symlink: entries[path] = "link:" + (try files.symlinkTarget(at: path))
            case .directory:
                entries[path] = "directory"
                for name in try files.listDirectory(at: path) { try visit(path + "/" + name) }
            default: entries[path] = "file:" + (try files.readData(at: path)).base64EncodedString()
            }
        }
        for root in roots { try visit(root) }
        return entries
    }

    func allDeployRoots(_ projects: [String]) -> [String] {
        projects.map { root + "/" + $0 } + Array(paths.deployPaths.userSkillsDirectories.values)
            + [paths.deployPaths.cursorUserRulesDirectory]
    }
}

@MainActor
private final class RemoteRemovalSession {
    let context: ModelContext
    let platform: PlatformViewModel
    let convergence: PostSyncConvergence

    init(paths: AppRuntimePaths, configuration: ModelConfiguration, files: FileService,
         store: SkillStore, state: DeployStateStore) throws {
        let container = try AppRuntime.makeContainer(configuration: configuration)
        context = ModelContext(container)
        platform = PlatformViewModel(fileService: files, linkService: LinkService(fileService: files, paths: paths.deployPaths),
            cursorCompiler: CursorCompiler(fileService: files, skillStore: store,
                userRulesDirectory: paths.deployPaths.cursorUserRulesDirectory),
            agentDetection: DeletionTestDetection(installed: RemoteRemovalFixture.agents),
            deployStateStore: state, skillsDirectory: paths.skillsDir)
        let intent = AppRuntime.makeLaunchIntentReconciler(platformVM: platform, paths: paths)
        convergence = paths.makeConvergence(container: container, platformVM: platform, intentReconciler: intent)
    }
}
