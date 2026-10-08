import XCTest
@testable import Pensieve

final class DeployPathsTests: XCTestCase {
    func testGeneratedArtifactPathsRoundTripEveryPlatformAndScope() {
        let slugs = ["x", "review-skill", "with spaces", "under_score", "has.md", "has.mdc", "café", "技能",
                     "\u{0301}accent", "e\u{0301}", "🧑‍💻", "العربية", "\u{200D}joiner"]
        for platform in PlatformTarget.allCases {
            for projectPath: String? in [nil, "/tmp/project", "/tmp/project with spaces", "relative-project"] {
                for slug in slugs {
                    let path = platform.usesSymlinks
                        ? TestPaths.deployPaths.linkPath(directoryName: slug, platform: platform, projectPath: projectPath)
                        : TestPaths.deployPaths.cursorPath(directoryName: slug, projectPath: projectPath)
                    let recovered = TestPaths.deployPaths.slug(artifactPath: path, platform: platform, projectPath: projectPath)
                    if projectPath == nil || platform.supportsProjectScope {
                        XCTAssertEqual(recovered, slug, "\(platform)/\(String(describing: projectPath))/\(slug)")
                    } else {
                        XCTAssertNil(recovered, "Unsupported project scope has no project inverse")
                    }
                    XCTAssertNil(TestPaths.deployPaths.slug(artifactPath: path + "/child", platform: platform,
                        projectPath: projectPath))
                    XCTAssertNil(TestPaths.deployPaths.slug(artifactPath: "/elsewhere" + path,
                                                  platform: platform, projectPath: projectPath))
                }
            }
        }
        for slug in slugs {
            let customRoot = "/tmp/user rules"
            let path = TestPaths.deployPaths.cursorPath(directoryName: slug, projectPath: nil, userRulesDirectory: customRoot)
            XCTAssertEqual(TestPaths.deployPaths.slug(artifactPath: path, platform: .cursor, projectPath: nil,
                                           cursorUserRulesDirectory: customRoot), slug)
            XCTAssertNil(TestPaths.deployPaths.slug(artifactPath: path, platform: .cursor, projectPath: nil))
        }
    }
    func testClaudeCodeTargetPathUsesCanonicalSkillsDir() {
        XCTAssertEqual(
            TestPaths.deployPaths.targetPath(directoryName: "x", platform: .claudeCode, projectPath: nil),
            TestPaths.skillsDir + "/x"
        )
    }

    func testLinkPathCases() {
        XCTAssertEqual(
            TestPaths.deployPaths.linkPath(directoryName: "x", platform: .claudeCode, projectPath: nil),
            TestPaths.deployPaths.userSkillsRoot(for: .claudeCode)! + "/x"
        )
        XCTAssertEqual(
            TestPaths.deployPaths.linkPath(directoryName: "x", platform: .codex, projectPath: nil),
            TestPaths.deployPaths.userSkillsRoot(for: .codex)! + "/x"
        )
        XCTAssertEqual(
            TestPaths.deployPaths.linkPath(directoryName: "x", platform: .codex, projectPath: "/tmp/project"),
            "/tmp/project/agents/x.md"
        )
        XCTAssertEqual(
            TestPaths.deployPaths.linkPath(directoryName: "x", platform: .hermes, projectPath: nil),
            (TestPaths.deployPaths.userSkillsRoot(for: .hermes)! as NSString).deletingLastPathComponent + "/pensieve/x"
        )
    }

    func testLinkServiceAdapterMatchesDeployPathsAcrossSymlinkPlatforms() {
        let skill = Skill(name: "x", directoryName: "x")
        let service = TestPaths.linkService(fileService: FileService())

        for platform in PlatformTarget.allCases where platform.usesSymlinks {
            XCTAssertEqual(
                service.linkPath(skill: skill, platform: platform, projectPath: nil),
                TestPaths.deployPaths.linkPath(directoryName: "x", platform: platform, projectPath: nil)
            )
            XCTAssertEqual(
                service.targetPath(skill: skill, platform: platform, projectPath: nil),
                TestPaths.deployPaths.targetPath(directoryName: "x", platform: platform, projectPath: nil)
            )
        }
    }
}
