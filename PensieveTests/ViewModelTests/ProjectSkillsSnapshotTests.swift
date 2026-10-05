import XCTest
@testable import Pensieve

private struct ProjectSnapshotDetection: AgentDetectionServiceProtocol {
    let installed: [PlatformTarget]

    func isInstalled(_ platform: PlatformTarget) -> Bool { installed.contains(platform) }
    func installedPlatforms() -> [PlatformTarget] { installed }
}

private final class ProjectSnapshotLinkService: LinkServiceProtocol {
    var deployedSlugs: Set<String>
    private(set) var checkedPlatforms: [PlatformTarget] = []
    private(set) var checkedProjectPaths: [String?] = []

    init(deployedSlugs: Set<String> = []) {
        self.deployedSlugs = deployedSlugs
    }

    func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {}
    func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool { false }
    func ownsArtifact(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool {
        return deployedSlugs.contains(skill.directoryName)
    }

    func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool {
        checkedPlatforms.append(platform)
        checkedProjectPaths.append(projectPath)
        return deployedSlugs.contains(skill.directoryName)
    }

    func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        (projectPath ?? "/tmp/user-wide") + "/" + platform.rawValue + "/" + skill.directoryName
    }

    func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        Constants.pensieveSkillsDir + "/" + skill.directoryName
    }

    func validateAll(skills: [Skill]) -> [BrokenLink] { [] }
}

private final class ProjectSnapshotCursorCompiler: CursorCompilerProtocol {
    var deployedSlugs: Set<String>
    private(set) var checkedProjectPaths: [String?] = []

    init(deployedSlugs: Set<String> = []) {
        self.deployedSlugs = deployedSlugs
    }

    func compile(skill: Skill, projectPath: String?) throws {}
    func remove(skill: Skill, projectPath: String?) throws -> Bool { false }
    func probeRulePresence(skill: Skill, projectPath: String?) throws -> Bool {
        return deployedSlugs.contains(skill.directoryName)
    }
    func ownsArtifact(skill: Skill, projectPath: String?) throws -> Bool {
        return deployedSlugs.contains(skill.directoryName)
    }
    func hasOwnershipMark(skill: Skill, projectPath: String?) throws -> Bool {
        return deployedSlugs.contains(skill.directoryName)
    }

    func isUpToDate(skill: Skill, projectPath: String?) -> Bool {
        checkedProjectPaths.append(projectPath)
        return deployedSlugs.contains(skill.directoryName)
    }

    func outputPath(skill: Skill, projectPath: String?) -> String {
        (projectPath ?? "/tmp/user-wide") + "/" + skill.directoryName + ".mdc"
    }
}

final class ProjectSkillsSnapshotTests: XCTestCase {
    private func makeProject(identityKey: String? = "project-key") -> Project {
        let project = Project(name: "Project", path: "/tmp/project")
        project.identityKey = identityKey
        return project
    }

    private func makeCategory(projectKey: String = "project-key", slugs: [String]) -> Pensieve.Category {
        let category = Pensieve.Category(name: "Category")
        category.projectKeys = [projectKey]
        category.skillSlugs = slugs
        return category
    }

    private func makePlatformVM(
        installed: [PlatformTarget] = [.claudeCode],
        linkService: ProjectSnapshotLinkService = ProjectSnapshotLinkService(),
        cursorCompiler: ProjectSnapshotCursorCompiler = ProjectSnapshotCursorCompiler()
    ) -> PlatformViewModel {
        PlatformViewModel(
            linkService: linkService,
            cursorCompiler: cursorCompiler,
            agentDetection: ProjectSnapshotDetection(installed: installed),
            deployStateStore: .memoryBacked
        )
    }

    func testLoadIncludesDeployedSkills() {
        let skill = Skill(name: "Deployed", directoryName: "deployed")
        let linkService = ProjectSnapshotLinkService(deployedSlugs: [skill.directoryName])

        let snapshot = ProjectSkillsSnapshot.load(
            project: makeProject(), skills: [skill], categories: [],
            platformVM: makePlatformVM(linkService: linkService)
        )

        XCTAssertEqual(snapshot.rows.count, 1)
        XCTAssertEqual(snapshot.rows.first?.skillID, skill.id)
        XCTAssertEqual(snapshot.rows.first?.isDeployed, true)
        XCTAssertEqual(snapshot.rows.first?.isIntended, false)
    }

    func testLoadIncludesIntendedSkillsNotYetDeployed() {
        let skill = Skill(name: "Intended", directoryName: "intended")

        let snapshot = ProjectSkillsSnapshot.load(
            project: makeProject(), skills: [skill],
            categories: [makeCategory(slugs: [skill.directoryName])],
            platformVM: makePlatformVM()
        )

        XCTAssertEqual(snapshot.rows.count, 1)
        XCTAssertEqual(snapshot.rows.first?.isDeployed, false)
        XCTAssertEqual(snapshot.rows.first?.isIntended, true)
    }

    func testLoadExcludesUnrelatedSkills() {
        let unrelated = Skill(name: "Unrelated", directoryName: "unrelated")

        let snapshot = ProjectSkillsSnapshot.load(
            project: makeProject(), skills: [unrelated], categories: [],
            platformVM: makePlatformVM()
        )

        XCTAssertTrue(snapshot.rows.isEmpty)
    }

    func testLoadWithoutIdentityKeyHasNoIntendedRows() {
        let skill = Skill(name: "Intended", directoryName: "intended")

        let snapshot = ProjectSkillsSnapshot.load(
            project: makeProject(identityKey: nil), skills: [skill],
            categories: [makeCategory(slugs: [skill.directoryName])],
            platformVM: makePlatformVM()
        )

        XCTAssertTrue(snapshot.rows.isEmpty)
    }

    func testLoadUsesProjectScopedPlatformsOnly() {
        let skill = Skill(name: "Skill", directoryName: "skill")
        let linkService = ProjectSnapshotLinkService()
        let cursorCompiler = ProjectSnapshotCursorCompiler()
        let project = makeProject()

        _ = ProjectSkillsSnapshot.load(
            project: project, skills: [skill], categories: [],
            platformVM: makePlatformVM(
                installed: [.claudeCode, .cursor, .openClaw, .hermes],
                linkService: linkService,
                cursorCompiler: cursorCompiler
            )
        )

        XCTAssertEqual(linkService.checkedPlatforms, [.claudeCode])
        XCTAssertEqual(linkService.checkedProjectPaths, [project.path])
        XCTAssertEqual(cursorCompiler.checkedProjectPaths, [project.path])
    }

    func testDeployedCountCountsOnlyDeployedRows() {
        let deployed = Skill(name: "Deployed", directoryName: "deployed")
        let intended = Skill(name: "Intended", directoryName: "intended")
        let linkService = ProjectSnapshotLinkService(deployedSlugs: [deployed.directoryName])

        let snapshot = ProjectSkillsSnapshot.load(
            project: makeProject(), skills: [deployed, intended],
            categories: [makeCategory(slugs: [intended.directoryName])],
            platformVM: makePlatformVM(linkService: linkService)
        )

        XCTAssertEqual(snapshot.rows.count, 2)
        XCTAssertEqual(snapshot.deployedCount, 1)
    }

    func testLoadReflectsEqualCountSlugSubstitution() {
        let first = Skill(name: "First", directoryName: "first")
        let second = Skill(name: "Second", directoryName: "second")
        let category = makeCategory(slugs: [first.directoryName])
        let project = makeProject()
        let platformVM = makePlatformVM()

        let before = ProjectSkillsSnapshot.load(
            project: project, skills: [first, second], categories: [category], platformVM: platformVM
        )
        category.skillSlugs = [second.directoryName]
        let after = ProjectSkillsSnapshot.load(
            project: project, skills: [first, second], categories: [category], platformVM: platformVM
        )

        XCTAssertEqual(before.rows.map { $0.directoryName }, [first.directoryName])
        XCTAssertEqual(after.rows.map { $0.directoryName }, [second.directoryName])
    }

    func testLoadDropsSkillWhenCategoryLosesProject() {
        let skill = Skill(name: "Intended", directoryName: "intended")
        let category = makeCategory(slugs: [skill.directoryName])
        let project = makeProject()
        let platformVM = makePlatformVM()

        let before = ProjectSkillsSnapshot.load(
            project: project, skills: [skill], categories: [category], platformVM: platformVM
        )
        category.projectKeys = []
        let after = ProjectSkillsSnapshot.load(
            project: project, skills: [skill], categories: [category], platformVM: platformVM
        )

        XCTAssertEqual(before.rows.map { $0.skillID }, [skill.id])
        XCTAssertTrue(after.rows.isEmpty)
    }
}
