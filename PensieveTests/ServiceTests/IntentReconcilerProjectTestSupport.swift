import SwiftData
@testable import Pensieve

struct ProjectIntentIdentityStub: MachineIdentityProviding {
    let id: String
    let fails: Bool

    init(id: String, fails: Bool = false) {
        self.id = id
        self.fails = fails
    }

    func identifier() throws -> String {
        if fails { throw ScenarioStubFailure() }
        return id
    }
}

@MainActor
struct ProjectIntentHarness {
    static let localID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    static let remoteID = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"

    let context: ModelContext
    let platformVM: PlatformViewModel
    let reconciler: IntentReconciler
    let fileService: ScenarioRecordingFileService
    let linkService: ScenarioRecordingLinkService

    init(
        installed: [PlatformTarget],
        identityFails: Bool = false,
        stateFetcher: ReconcilerStateFetching = ReconcilerStateFetcher(),
        persist: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        context = ModelContext(try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        ))
        fileService = ScenarioRecordingFileService()
        linkService = ScenarioRecordingLinkService(fileService: fileService)
        platformVM = PlatformViewModel(
            fileService: fileService,
            linkService: linkService,
            cursorCompiler: ScenarioRecordingCursorCompiler(fileService: fileService),
            agentDetection: ScenarioStubDetection(installed: installed),
            deployStateStore: DeployStateStore(fileService: fileService),
            persist: persist
        )
        reconciler = IntentReconciler(
            platformVM: platformVM,
            machineIdentity: ProjectIntentIdentityStub(id: Self.localID, fails: identityFails),
            stateFetcher: stateFetcher
        )
    }

    @discardableResult
    func insertSkill(_ slug: String) throws -> Skill {
        let skill = Skill(
            name: slug, skillDescription: slug + " description", tags: [], scope: .user,
            directoryName: slug, cursorConfig: nil, importedFrom: nil
        )
        context.insert(skill)
        try context.save()
        return skill
    }

    @discardableResult
    func insertProject(name: String, path: String, key: String) throws -> Project {
        let project = Project(name: name, path: path)
        project.identityKey = key
        context.insert(project)
        try context.save()
        return project
    }

    @discardableResult
    func insertIntent(
        skill: Skill,
        platformRaw: String,
        projectKey: String? = nil,
        machineID: String = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    ) throws -> MachineDeployIntent {
        let intent = MachineDeployIntent(
            machineID: machineID,
            skillSlug: skill.directoryName,
            platformRaw: platformRaw,
            projectKey: projectKey
        )
        context.insert(intent)
        try context.save()
        return intent
    }

    func assignments() throws -> [IntentAssignment] {
        try context.fetch(FetchDescriptor<IntentAssignment>())
    }

    func intents() throws -> [MachineDeployIntent] {
        try context.fetch(FetchDescriptor<MachineDeployIntent>())
    }

    func artifactPath(skill: Skill, platform: PlatformTarget, project: Project?) -> String {
        linkService.linkPath(skill: skill, platform: platform, projectPath: project?.path)
    }
}

struct NoopProjectCategoryReconciler: CategoryReconcilerProtocol {
    func reconcile(context: ModelContext) -> BatchResult { BatchResult() }
}
