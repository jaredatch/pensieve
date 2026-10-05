import Foundation
import SwiftData
@testable import Pensieve

/// Real FileService operations stay inside a unique root. Only the canonical store path is
/// translated; the existing containment double rejects unmodeled live paths. Checkpoints stage
/// disappearance and lookup failure, and cannot replace a filesystem operation.
@MainActor
struct ProjectFolderCallerHarness {
    let root: String
    let files: FileService
    let mapped: LinkServiceCanonicalDirectoryFileService
    let context: ModelContext
    let platformVM: PlatformViewModel
    let intent: IntentReconciler
    let category: CategoryReconciler
    let deployState: DeployStateStore
    let skill: Skill
    let project: Project
    let otherProject: Project

    init(installed: [PlatformTarget] = [.claudeCode, .grok, .codex, .cursor], files: FileService = FileService(),
         persistent: Bool = false) throws {
        self.files = files
        root = NSTemporaryDirectory() + "ProjectFolderCallers-\(UUID().uuidString)"
        let store = SkillStore(fileService: files, baseDir: root + "/store/skills")
        let slug = try store.createSkill(name: "Caller Skill", description: "Caller", body: "# Body")
        mapped = LinkServiceCanonicalDirectoryFileService(
            wrapped: files,
            pathMappings: [(logical: Constants.pensieveSkillsDir, physical: root + "/store/skills")],
            physicalSandbox: root
        )
        context = ModelContext(try AppRuntime.makeContainer(
            configuration: persistent ? ModelConfiguration(url: URL(fileURLWithPath: root + "/removal.sqlite"))
                : ModelConfiguration(isStoredInMemoryOnly: true)
        ))
        deployState = DeployStateStore(fileService: mapped, appSupportDir: root + "/support")
        platformVM = PlatformViewModel(
            fileService: mapped,
            agentDetection: DeployStubDetection(installed: installed),
            deployStateStore: deployState
        )
        intent = IntentReconciler(
            platformVM: platformVM,
            machineIdentity: ProjectIntentIdentityStub(id: ProjectIntentHarness.localID),
            handoverIsComplete: { true }
        )
        category = CategoryReconciler(platformVM: platformVM)
        skill = Skill(name: "Caller Skill", directoryName: slug)
        project = Project(name: "Archived Project", path: root + "/absent/parent/project")
        project.identityKey = "github.com/owner/project"
        otherProject = Project(name: "Available Project", path: root + "/available")
        otherProject.identityKey = "github.com/owner/available"
        try files.createDirectory(at: otherProject.path)
        context.insert(skill)
        context.insert(project)
        context.insert(otherProject)
        try context.save()
    }

    func cleanup() { try? files.deleteDirectory(at: root) }

    func addIntent(platform: PlatformTarget = .codex, project: Project? = nil) throws {
        let target = project ?? self.project
        context.insert(MachineDeployIntent(
            machineID: ProjectIntentHarness.localID, skillSlug: skill.directoryName,
            platformRaw: platform.rawValue, projectKey: target.identityKey
        ))
        try context.save()
    }

    func addCategory() throws -> Pensieve.Category {
        let rule = Pensieve.Category(name: "Caller Category")
        rule.skillSlugs = [skill.directoryName]
        rule.projectKeys = [project.identityKey!]
        context.insert(rule)
        try context.save()
        return rule
    }

    func model() -> DeployIntentModel {
        let manifest = ManifestService(fileService: files)
        return DeployIntentModel(platformVM: platformVM, dependencies: DeployIntentDependencies(
            identity: ProjectIntentIdentityStub(id: ProjectIntentHarness.localID),
            stateService: MachineStateService(fileService: mapped), root: root + "/store",
            writeManifest: { context in
                try manifest.write(try manifest.snapshot(from: context), toRoot: root + "/store")
            }, notifier: {}, reconcile: { intent.reconcile(context: $0) },
            lockPath: root + "/support/intent.lock", remoteRetractions: RemoteRetractionStore()
        ))
    }

    func convergence(audit: @escaping (String, String) -> Void) -> PostSyncConvergence {
        PostSyncConvergence(
            root: root + "/store", deployReconciler: ConvergenceRecordingDeploy(recorder: ConvergenceRecorder()),
            contextFactory: { context }, categoryReconciler: category, intentReconciler: intent,
            auditLog: audit
        )
    }

    func artifact(_ platform: PlatformTarget, project: Project? = nil) -> String {
        DeployPaths.linkPath(directoryName: skill.directoryName, platform: platform, projectPath: (project ?? self.project).path)
    }
}
