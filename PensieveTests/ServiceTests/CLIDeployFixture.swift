import Foundation
import SwiftData
@testable import Pensieve

/// Real store, manifest, agent artifacts and deploy-state files are contained below this owned
/// root. Agent detection and machine observations are supplied; no live agents or remotes are read.
@MainActor
final class CLIDeployFixture {
    static let localID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    static let remoteID = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    let directory: SocketTestDirectory
    let context: ModelContext
    let platform: PlatformViewModel
    let service: DeployMutationService
    let project: Project
    let keyless: Project
    let skill: Skill
    let other: Skill
    let store: SkillStore
    let manifest: ManifestService
    let root: String
    let lock: String
    var handler: CLIDeployHandler { CLIDeployHandler(service: service, files: directory.files) }
    var readHandler: CLIReadHandler {
        CLIReadHandler(store: store, installedAgents: platform.installedPlatforms, deployments: service)
    }

    init(installed: [PlatformTarget] = [.claudeCode, .codex, .cursor, .hermes],
         save: @escaping (ModelContext) throws -> Void = { try $0.save() },
         reconcile: ((ModelContext) -> BatchResult)? = nil, states observedStates: [MachineState]? = nil,
         platformSave: @escaping (ModelContext) throws -> Void = { try $0.save() },
         beforeManifestWrite: (() throws -> Void)? = nil) throws {
        let directory = try SocketTestDirectory()
        self.directory = directory
        root = directory.path + "/store"
        lock = directory.path + "/sync.lock"
        let files = directory.files
        let root = root
        let manifest = ManifestService(fileService: files)
        self.manifest = manifest
        let store = SkillStore(fileService: files, baseDir: root + "/skills", storeRoot: root)
        self.store = store
        let slug = try store.createSkill(name: "Review", description: "Review", body: "# Review")
        let otherSlug = try store.createSkill(name: "Other", description: "Other", body: "# Other")
        context = ModelContext(try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
        skill = Skill(name: "Review", skillDescription: "Review", directoryName: slug)
        other = Skill(name: "Other", skillDescription: "Other", directoryName: otherSlug)
        project = Project(name: "App", path: directory.path + "/project")
        project.identityKey = "github.com/fixture/app"
        keyless = Project(name: "Local", path: directory.path + "/local")
        for project in [project, keyless] { try files.createDirectory(at: project.path); context.insert(project) }
        context.insert(skill)
        context.insert(other)
        try context.save()
        let paths = DeployPaths(skillsDirectory: root + "/skills", userSkillsDirectories:
            Dictionary(uniqueKeysWithValues: PlatformTarget.allCases.map { ($0, directory.path + "/agents/" + $0.cliID) }),
            cursorUserRulesDirectory: directory.path + "/agents/cursor")
        platform = Self.makePlatform(files: files, store: store, paths: paths, directory: directory.path,
            installed: installed, persist: platformSave)
        let platform = platform
        let identity = DeployIntentIdentityStub(id: Self.localID)
        let states = observedStates ?? [MachineState(schemaVersion: 1, machineID: Self.remoteID,
            name: "Mini", appVersion: "fixture",
            publishedAt: Date(), agents: ["claudeCode", "codex"], projects: [], userDeploys: [], projectDeploys: [])]
        let scoped: (@MainActor ([DeployMutationPair], ModelContext) -> BatchResult)?
        if reconcile == nil {
            scoped = { pairs, context in
                IntentReconciler(platformVM: platform, machineIdentity: identity).reconcileSelection(pairs, context: context)
            }
        } else { scoped = nil }
        service = DeployMutationService(platformVM: platform, dependencies: DeployIntentDependencies(identity: identity,
            stateService: DeployIntentStateStub(states: states), root: root, manifestService: manifest,
            writeManifest: {
                try beforeManifestWrite?()
                try manifest.write(try manifest.snapshot(from: $0), toRoot: root)
            }, saveContext: save,
            notifier: {}, reconcile: reconcile ?? { IntentReconciler(platformVM: platform, machineIdentity: identity)
                .reconcile(context: $0) }, reconcileSelection: scoped, lockPath: lock))
        try manifest.write(try manifest.snapshot(from: context), toRoot: root)
        guard let initialLock = SyncLock.tryAcquire(at: lock) else { throw DeployStubFailure() }
        initialLock.release()
    }

    private static func makePlatform(files: FileService, store: SkillStore, paths: DeployPaths,
                                     directory: String, installed: [PlatformTarget],
                                     persist: @escaping (ModelContext) throws -> Void) -> PlatformViewModel {
        PlatformViewModel(fileService: files, linkService: LinkService(fileService: files, paths: paths),
            cursorCompiler: CursorCompiler(fileService: files, skillStore: store,
                userRulesDirectory: paths.cursorUserRulesDirectory),
            agentDetection: DeployStubDetection(installed: installed),
            deployStateStore: DeployStateStore(fileService: files, appSupportDir: directory + "/support"),
            skillsDirectory: paths.skillsDirectory, persist: persist)
    }

    func request(_ command: String = "deploy", skills: [String]? = nil, agents: [String] = ["claude"],
                 project: String? = nil, machines: [String] = [], dryRun: Bool = false) -> CLIRequest {
        CLIRequest(command: command, arguments: skills ?? [skill.directoryName], deployment: CLIDeployOptions(
            agents: agents, global: project == nil, project: project, machines: machines, dryRun: dryRun,
            workingDirectory: self.project.path))
    }

    func intents() throws -> Set<String> { Set(try context.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.key)) }

    func tree() throws -> [String: Data] {
        func walk(_ path: String) throws -> [String: Data] {
            let files = directory.files
            let identity = Data(String(describing: files.fileIdentity(at: path, followingLinks: false)).utf8) + Data([0])
            if files.isSymlink(at: path) { return [path: identity + Data(try files.symlinkTarget(at: path).utf8)] }
            if !files.directoryExists(at: path) { return [path: identity + (try files.readData(at: path))] }
            var entries: [String: Data] = [path: identity]
            for name in try files.listDirectory(at: path) {
                entries.merge(try walk(path + "/" + name)) { first, _ in first }
            }
            return entries
        }
        return try walk(directory.path)
    }
}
