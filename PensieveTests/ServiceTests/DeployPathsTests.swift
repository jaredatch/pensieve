import XCTest
@testable import Pensieve

final class DeployPathsTests: XCTestCase {
    func testGeneratedArtifactPathsRoundTripEveryPlatformAndScope() {
        let slugs = ["x", "review-skill", "with spaces", "under_score", "has.md", "has.mdc", "café", "技能"]
        for platform in PlatformTarget.allCases {
            for projectPath: String? in [nil, "/tmp/project", "/tmp/project with spaces", "relative-project"] {
                for slug in slugs {
                    let path = platform.usesSymlinks
                        ? DeployPaths.linkPath(directoryName: slug, platform: platform, projectPath: projectPath)
                        : DeployPaths.cursorPath(directoryName: slug, projectPath: projectPath)
                    let recovered = DeployPaths.slug(artifactPath: path, platform: platform, projectPath: projectPath)
                    if projectPath == nil || platform.supportsProjectScope {
                        XCTAssertEqual(recovered, slug, "\(platform)/\(String(describing: projectPath))/\(slug)")
                    } else {
                        XCTAssertNil(recovered, "Unsupported project scope has no project inverse")
                    }
                    XCTAssertNil(DeployPaths.slug(artifactPath: path + "/child", platform: platform, projectPath: projectPath))
                    XCTAssertNil(DeployPaths.slug(artifactPath: "/elsewhere" + path,
                                                  platform: platform, projectPath: projectPath))
                }
            }
        }
        for slug in slugs {
            let customRoot = "/tmp/user rules"
            let path = DeployPaths.cursorPath(directoryName: slug, projectPath: nil, userRulesDirectory: customRoot)
            XCTAssertEqual(DeployPaths.slug(artifactPath: path, platform: .cursor, projectPath: nil,
                                           cursorUserRulesDirectory: customRoot), slug)
            XCTAssertNil(DeployPaths.slug(artifactPath: path, platform: .cursor, projectPath: nil))
        }
    }
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
