import XCTest
@testable import Pensieve

final class GrokDeployTests: XCTestCase {
    private var fileService: FileService!
    private var tempDir: String!

    override func setUpWithError() throws {
        fileService = FileService()
        tempDir = TestTemporaryDirectory.path + "PensieveGrokDeployTests-\(UUID().uuidString)"
        try fileService.createDirectory(at: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir, fileService.directoryExists(at: tempDir) {
            try fileService.deleteDirectory(at: tempDir)
        }
    }

    func testUserWideLinkAndUnlink() throws {
        let context = try makeUserWideContext()

        try context.service.link(skill: context.skill, platform: .grok, projectPath: nil)

        XCTAssertTrue(fileService.isSymlink(at: context.physicalLink))
        XCTAssertEqual(try fileService.symlinkTarget(at: context.physicalLink), context.physicalTarget)
        XCTAssertTrue(context.service.isLinked(
            skill: context.skill, platform: .grok, projectPath: nil))

        try context.service.unlink(skill: context.skill, platform: .grok, projectPath: nil)

        XCTAssertFalse(fileService.isSymlink(at: context.physicalLink))
        XCTAssertFalse(context.service.isLinked(
            skill: context.skill, platform: .grok, projectPath: nil))
    }

    func testProjectScopedLinkCreatesIntermediateDirs() throws {
        let skill = makeSkill()
        let projectPath = tempDir + "/project"
        try fileService.createDirectory(at: projectPath)
        let service = try makeProjectService(skill: skill)
        let skillsPath = projectPath + "/.grok/skills"
        XCTAssertFalse(fileService.directoryExists(at: skillsPath))

        try service.link(skill: skill, platform: .grok, projectPath: projectPath)

        let link = skillsPath + "/" + skill.directoryName
        XCTAssertTrue(fileService.directoryExists(at: projectPath + "/.grok"))
        XCTAssertTrue(fileService.directoryExists(at: skillsPath))
        XCTAssertTrue(fileService.isSymlink(at: link))
        XCTAssertTrue(service.isLinked(skill: skill, platform: .grok, projectPath: projectPath))
    }

    func testRedeployIsIdempotent() throws {
        let skill = makeSkill()
        let projectPath = tempDir + "/redeploy-project"
        try fileService.createDirectory(at: projectPath)
        let service = try makeProjectService(skill: skill)

        try service.link(skill: skill, platform: .grok, projectPath: projectPath)
        try service.link(skill: skill, platform: .grok, projectPath: projectPath)

        let physicalLink = projectPath + "/.grok/skills/" + skill.directoryName
        XCTAssertTrue(fileService.isSymlink(at: physicalLink))
        XCTAssertTrue(service.isLinked(skill: skill, platform: .grok, projectPath: projectPath))
    }

    func testRetargetedForeignLinkIsRefused() throws {
        let context = try makeUserWideContext()
        let foreignTarget = tempDir + "/retargeted"
        try fileService.createDirectory(at: foreignTarget)
        try fileService.createSymlink(at: context.physicalLink, pointingTo: foreignTarget)

        XCTAssertEqual(context.service.validateAll(skills: [context.skill]).count, 1)
        XCTAssertFalse(context.service.isLinked(
            skill: context.skill, platform: .grok, projectPath: nil))

        XCTAssertThrowsError(try context.service.link(skill: context.skill, platform: .grok, projectPath: nil))
        XCTAssertEqual(try fileService.symlinkTarget(at: context.physicalLink), foreignTarget)
        XCTAssertFalse(context.service.isLinked(skill: context.skill, platform: .grok, projectPath: nil))
    }

    func testForeignSymlinkIsRemovedOnUnlink() throws {
        let context = try makeUserWideContext()
        let foreignTarget = tempDir + "/foreign-owner/skill"
        try fileService.createDirectory(at: foreignTarget)
        try fileService.createSymlink(at: context.physicalLink, pointingTo: foreignTarget)
        XCTAssertNotEqual(foreignTarget, context.physicalTarget)

        try context.service.unlink(skill: context.skill, platform: .grok, projectPath: nil)

        XCTAssertTrue(fileService.isSymlink(at: context.physicalLink))
        XCTAssertEqual(try fileService.symlinkTarget(at: context.physicalLink), foreignTarget)
        XCTAssertTrue(fileService.directoryExists(at: foreignTarget))
    }

    func testStaleProjectRootDoesNotCreateShadowTree() throws {
        let skill = makeSkill()
        let staleProject = tempDir + "/writable-parent/missing/project"
        let service = try makeProjectService(skill: skill)
        XCTAssertFalse(fileService.directoryExists(at: staleProject))

        XCTAssertThrowsError(try service.link(skill: skill, platform: .grok, projectPath: staleProject)) { error in
            guard case ProjectFolderError.missing(let path) = error else {
                return XCTFail("Expected missing project folder, got \(error)")
            }
            XCTAssertEqual(path, staleProject)
        }
        XCTAssertFalse(fileService.directoryExists(at: tempDir + "/writable-parent"))
        XCTAssertFalse(fileService.directoryExists(at: staleProject))
        XCTAssertFalse(service.isLinked(skill: skill, platform: .grok, projectPath: staleProject))
    }

    func testInvalidPathComponentRejected() {
        let service = LinkService(fileService: fileService)
        for component in ["..", "nested/skill"] {
            let skill = makeSkill(directoryName: component)
            XCTAssertThrowsError(try service.link(
                skill: skill, platform: .grok, projectPath: tempDir + "/project"
            )) { error in
                guard case LinkError.invalidPathComponent(let rejected) = error else {
                    return XCTFail("Expected invalidPathComponent, got \(error)")
                }
                XCTAssertEqual(rejected, component)
            }
        }
    }

    private func makeSkill(directoryName: String = "grok-lifecycle") -> Skill {
        Skill(name: "Grok Lifecycle", directoryName: directoryName)
    }

    private func makeProjectService(skill: Skill) throws -> LinkService {
        let logicalTarget = Constants.pensieveSkillsDir + "/" + skill.directoryName
        let physicalTarget = tempDir + "/pensieve/skills/" + skill.directoryName
        try fileService.createDirectory(at: physicalTarget)
        return LinkService(fileService: LinkServiceCanonicalDirectoryFileService(
            wrapped: fileService,
            canonicalDirectory: logicalTarget,
            substituteDirectory: physicalTarget))
    }

    private func makeUserWideContext() throws -> UserWideContext {
        let skill = makeSkill()
        let logicalTarget = Constants.pensieveSkillsDir + "/" + skill.directoryName
        let physicalTarget = tempDir + "/pensieve/skills/" + skill.directoryName
        let physicalGrokRoot = tempDir + "/home/.grok/skills"
        try fileService.createDirectory(at: physicalTarget)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let literalUserRoots: [PlatformTarget: String] = [
            .claudeCode: home + "/.claude/skills",
            .grok: home + "/.grok/skills",
            .codex: home + "/.codex/skills",
            .openClaw: home + "/.openclaw/skills",
            .hermes: home + "/.hermes/skills/pensieve"
        ]
        XCTAssertEqual(
            Set(literalUserRoots.keys),
            Set(PlatformTarget.allCases.filter(\.usesSymlinks)),
            "New symlink platform must be added to this hermetic seam's literal root table")

        var mappings = [(logical: logicalTarget, physical: physicalTarget)]
        for (platform, logicalRoot) in literalUserRoots {
            let physicalRoot = platform == .grok
                ? physicalGrokRoot
                : tempDir + "/shadow-user-roots/" + platform.rawValue
            mappings.append((logical: logicalRoot, physical: physicalRoot))
        }
        let translated = LinkServiceCanonicalDirectoryFileService(
            wrapped: fileService, pathMappings: mappings, physicalSandbox: tempDir)
        return UserWideContext(
            service: LinkService(fileService: translated),
            skill: skill,
            physicalLink: physicalGrokRoot + "/" + skill.directoryName,
            physicalTarget: physicalTarget)
    }
}

private struct UserWideContext {
    let service: LinkService
    let skill: Skill
    let physicalLink: String
    let physicalTarget: String
}
