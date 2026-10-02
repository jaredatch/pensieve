import XCTest
@testable import Pensieve

final class DeployPathsTests: XCTestCase {
    func testClaudeCodeTargetPathUsesCanonicalSkillsDir() {
        XCTAssertEqual(
            DeployPaths.targetPath(directoryName: "x", platform: .claudeCode, projectPath: nil),
            PathConstants.pensieveSkillsDir + "/x"
        )
    }

    func testLinkPathCases() {
        XCTAssertEqual(
            DeployPaths.linkPath(directoryName: "x", platform: .claudeCode, projectPath: nil),
            PathConstants.claudeCodeUserSkillsDir + "/x"
        )
        XCTAssertEqual(
            DeployPaths.linkPath(directoryName: "x", platform: .codex, projectPath: nil),
            PathConstants.codexUserSkillsDir + "/x"
        )
        XCTAssertEqual(
            DeployPaths.linkPath(directoryName: "x", platform: .codex, projectPath: "/tmp/project"),
            "/tmp/project/agents/x.md"
        )
        XCTAssertEqual(
            DeployPaths.linkPath(directoryName: "x", platform: .hermes, projectPath: nil),
            PathConstants.hermesUserSkillsDir + "/pensieve/x"
        )
    }

    func testLinkServiceAdapterMatchesDeployPathsAcrossSymlinkPlatforms() {
        let skill = Skill(name: "x", directoryName: "x")
        let service = LinkService(fileService: FileService())

        for platform in PlatformTarget.allCases where platform.usesSymlinks {
            XCTAssertEqual(
                service.linkPath(skill: skill, platform: platform, projectPath: nil),
                DeployPaths.linkPath(directoryName: "x", platform: platform, projectPath: nil)
            )
            XCTAssertEqual(
                service.targetPath(skill: skill, platform: platform, projectPath: nil),
                DeployPaths.targetPath(directoryName: "x", platform: platform, projectPath: nil)
            )
        }
    }
}
