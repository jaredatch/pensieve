import XCTest
@testable import Pensieve

extension LinkServiceTests {
    func testUnsupportedProjectScopePreservesUserWideLinksAndReportsUndeployed() throws {
        let skill = makeSkill()
        let project = Project(name: "Stale", path: tempDir + "/project")
        let canonical = Constants.pensieveSkillsDir + "/" + skill.directoryName
        let physicalSkill = tempDir + "/store/" + skill.directoryName
        try fileService.writeFile(at: physicalSkill + "/SKILL.md", content: "body")
        for platform in [PlatformTarget.openClaw, .hermes] {
            let userPath = DeployPaths.linkPath(directoryName: skill.directoryName, platform: platform, projectPath: nil)
            let physicalLink = tempDir + "/user/" + platform.rawValue
            let mapped = LinkServiceCanonicalDirectoryFileService(
                wrapped: fileService, pathMappings: [(canonical, physicalSkill), (userPath, physicalLink)],
                physicalSandbox: tempDir
            )
            let links = LinkService(fileService: mapped)
            let vm = PlatformViewModel(fileService: mapped, linkService: links,
                                       agentDetection: DeployStubDetection(installed: []), deployStateStore: .memoryBacked)
            try links.link(skill: skill, platform: platform, projectPath: nil)
            XCTAssertTrue(links.isLinked(skill: skill, platform: platform, projectPath: nil))
            XCTAssertTrue(try vm.removalOperation(skill: skill, platform: platform, target: .userWide).classify().isOwned)
            XCTAssertFalse(links.isLinked(skill: skill, platform: platform, projectPath: project.path))
            XCTAssertFalse(try vm.removalOperation(
                skill: skill, platform: platform, target: .project(project)).classify().isOwned)
            XCTAssertNoThrow(try links.unlink(skill: skill, platform: platform, projectPath: project.path))
            XCTAssertTrue(fileService.isSymlink(at: physicalLink), "A stale project row cannot delete the user-wide link")
            XCTAssertTrue(links.isLinked(skill: skill, platform: platform, projectPath: nil))
            XCTAssertEqual(try fileService.readFile(at: physicalSkill + "/SKILL.md"), "body")
            try links.unlink(skill: skill, platform: platform, projectPath: nil)
            XCTAssertFalse(fileService.isSymlink(at: physicalLink))
            XCTAssertFalse(links.isLinked(skill: skill, platform: platform, projectPath: nil))
            XCTAssertFalse(try vm.removalOperation(skill: skill, platform: platform, target: .userWide).classify().isOwned)
        }
    }
}
