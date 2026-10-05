import SwiftData
import XCTest
@testable import Pensieve

private typealias PensieveCategory = Pensieve.Category

private struct RecordedLink: Hashable {
    let directoryName: String
    let platform: PlatformTarget
    let projectPath: String?
}

private final class RecordingLinkService: LinkServiceProtocol {
    var linkCalls: [RecordedLink] = []
    var unlinkCalls: [RecordedLink] = []
    private var artifacts: Set<RecordedLink> = []

    func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
        let artifact = RecordedLink(directoryName: skill.directoryName, platform: platform, projectPath: projectPath)
        linkCalls.append(artifact)
        artifacts.insert(artifact)
    }

    func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
        let artifact = RecordedLink(directoryName: skill.directoryName, platform: platform, projectPath: projectPath)
        unlinkCalls.append(artifact)
        artifacts.remove(artifact)
    }
    func ownsArtifact(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool {
        artifacts.contains(RecordedLink(directoryName: skill.directoryName, platform: platform, projectPath: projectPath))
    }

    func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool {
        artifacts.contains(RecordedLink(directoryName: skill.directoryName, platform: platform, projectPath: projectPath))
    }

    func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        (projectPath ?? "/tmp/user-wide") + "/links/" + platform.rawValue + "/" + skill.directoryName
    }

    func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        (projectPath ?? "/tmp/user-wide") + "/targets/" + platform.rawValue + "/" + skill.directoryName
    }

    func validateAll(skills: [Skill]) -> [BrokenLink] { [] }
}

private final class StubDetection: AgentDetectionServiceProtocol {
    var installed: [PlatformTarget]

    init(installed: [PlatformTarget]) {
        self.installed = installed
    }

    func isInstalled(_ platform: PlatformTarget) -> Bool { installed.contains(platform) }
    func installedPlatforms() -> [PlatformTarget] { installed }
}

private struct StubFileService: FileServiceProtocol {
    func readFile(at path: String) throws -> String { "" }
    func writeFile(at path: String, content: String) throws {}
    func deleteFile(at path: String) throws {}
    func fileExists(at path: String) -> Bool { false }
    func isExecutableFile(at path: String) -> Bool { false }
    func directoryExists(at path: String) -> Bool { false }
    func directoryExistsFollowingLinks(at path: String) throws -> Bool { path.hasPrefix("/tmp/") }
    func createDirectory(at path: String) throws {}
    func deleteDirectory(at path: String) throws {}
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {}
    func symlinkTarget(at path: String) throws -> String { "" }
    func isSymlink(at path: String) -> Bool { false }
    func isRegularFile(at path: String) -> Bool { true }
    func listDirectory(at path: String) throws -> [String] { [] }
    func contentsHash(at path: String) throws -> String { "hash" }
}

final class CategoryDetailModelTests: XCTestCase {

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self,
            IntentAssignment.self, DeployRecord.self, PensieveCategory.self, Scenario.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func makeModel(linkService: RecordingLinkService) -> CategoryDetailModel {
        let platformVM = PlatformViewModel(
            fileService: StubFileService(),
            linkService: linkService,
            agentDetection: StubDetection(installed: [.claudeCode, .codex]), deployStateStore: .memoryBacked
        )
        return CategoryDetailModel(reconciler: CategoryReconciler(platformVM: platformVM))
    }

    @MainActor
    private func makeSkill(directoryName: String = "skill-s", context: ModelContext) -> Skill {
        let skill = Skill(name: "Skill S", directoryName: directoryName)
        context.insert(skill)
        return skill
    }

    @MainActor
    private func makeProject(path: String = "/tmp/project-p", key: String? = "project-key", context: ModelContext) -> Project {
        let project = Project(name: "Project P", path: path)
        project.identityKey = key
        context.insert(project)
        return project
    }

    @MainActor
    private func makeCategory(
        name: String = "Category C",
        skillSlugs: [String] = [],
        projectKeys: [String] = [],
        context: ModelContext
    ) -> PensieveCategory {
        let category = PensieveCategory(name: name)
        category.skillSlugs = skillSlugs
        category.projectKeys = projectKeys
        context.insert(category)
        return category
    }

    @MainActor
    private func ledgerRows(context: ModelContext) throws -> [SkillProjectAssignment] {
        try context.fetch(FetchDescriptor<SkillProjectAssignment>())
    }

    @MainActor
    func testSetSkillAssignDeploysAcrossInstalledAgentsAndSetsLastResult() throws {
        let context = try makeContext()
        let skill = makeSkill(context: context)
        let project = makeProject(context: context)
        let category = makeCategory(projectKeys: [project.identityKey!], context: context)
        try context.save()
        let linkService = RecordingLinkService()
        let model = makeModel(linkService: linkService)

        model.setSkill(skill, inCategory: category, assigned: true, context: context)

        XCTAssertEqual(Set(linkService.linkCalls), Set([
            RecordedLink(directoryName: skill.directoryName, platform: .claudeCode, projectPath: project.path),
            RecordedLink(directoryName: skill.directoryName, platform: .codex, projectPath: project.path)
        ]))
        XCTAssertEqual(model.lastResult?.successes.count, 2)
        XCTAssertEqual(model.lastResult?.hasFailures, false)
        XCTAssertEqual(try ledgerRows(context: context).count, 2)
    }

    @MainActor
    func testSetSkillUnassignRemoves() throws {
        let context = try makeContext()
        let skill = makeSkill(context: context)
        let project = makeProject(context: context)
        let category = makeCategory(projectKeys: [project.identityKey!], context: context)
        try context.save()
        let linkService = RecordingLinkService()
        let model = makeModel(linkService: linkService)
        model.setSkill(skill, inCategory: category, assigned: true, context: context)
        linkService.unlinkCalls.removeAll()

        model.setSkill(skill, inCategory: category, assigned: false, context: context)

        XCTAssertEqual(Set(linkService.unlinkCalls), Set([
            RecordedLink(directoryName: skill.directoryName, platform: .claudeCode, projectPath: project.path),
            RecordedLink(directoryName: skill.directoryName, platform: .codex, projectPath: project.path)
        ]))
        XCTAssertEqual(model.lastResult?.successes.count, 2)
        XCTAssertEqual(try ledgerRows(context: context).count, 0)
    }

    @MainActor
    func testSetProjectTogglesMembershipAndReconciles() throws {
        let context = try makeContext()
        let skill = makeSkill(context: context)
        let project = makeProject(context: context)
        let category = makeCategory(skillSlugs: [skill.directoryName], context: context)
        try context.save()
        let linkService = RecordingLinkService()
        let model = makeModel(linkService: linkService)

        model.setProject(project, inCategory: category, member: true, context: context)

        XCTAssertTrue(category.projectKeys.contains(project.identityKey!))
        XCTAssertEqual(Set(linkService.linkCalls), Set([
            RecordedLink(directoryName: skill.directoryName, platform: .claudeCode, projectPath: project.path),
            RecordedLink(directoryName: skill.directoryName, platform: .codex, projectPath: project.path)
        ]))
        XCTAssertEqual(try ledgerRows(context: context).count, 2)

        linkService.unlinkCalls.removeAll()
        model.setProject(project, inCategory: category, member: false, context: context)

        XCTAssertFalse(category.projectKeys.contains(project.identityKey!))
        XCTAssertEqual(Set(linkService.unlinkCalls), Set([
            RecordedLink(directoryName: skill.directoryName, platform: .claudeCode, projectPath: project.path),
            RecordedLink(directoryName: skill.directoryName, platform: .codex, projectPath: project.path)
        ]))
        XCTAssertEqual(try ledgerRows(context: context).count, 0)
    }

    @MainActor
    func testSetProjectPendingIdentityIsNoOp() throws {
        let context = try makeContext()
        let skill = makeSkill(context: context)
        let project = makeProject(key: nil, context: context)
        let category = makeCategory(skillSlugs: [skill.directoryName], context: context)
        try context.save()
        let linkService = RecordingLinkService()
        let model = makeModel(linkService: linkService)

        model.setProject(project, inCategory: category, member: true, context: context)

        XCTAssertTrue(linkService.linkCalls.isEmpty)
        XCTAssertTrue(category.projectKeys.isEmpty)
        XCTAssertEqual(try ledgerRows(context: context).count, 0)
    }
}
