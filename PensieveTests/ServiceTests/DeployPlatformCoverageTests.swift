import Foundation
import XCTest
@testable import Pensieve

final class DeployPlatformCoverageTests: XCTestCase {
    private let paths = RuntimePaths.production
    func testEverySymlinkPlatformRootMatchesItsLinkPathParent() throws {
        for platform in PlatformTarget.allCases where platform.usesSymlinks {
            let root = try XCTUnwrap(paths.deployPaths.userSkillsRoot(for: platform))
            let linkPath = paths.deployPaths.linkPath(
                directoryName: "coverage-fixture",
                platform: platform,
                projectPath: nil
            )
            XCTAssertEqual(root, (linkPath as NSString).deletingLastPathComponent)
        }
    }

    func testEverySymlinkPlatformInDaemonPruneList() throws {
        let pruneDirectories = DeployReconciler.agentSkillDirs(paths: paths.deployPaths)
        for platform in PlatformTarget.allCases where platform.usesSymlinks {
            let root = try XCTUnwrap(paths.deployPaths.userSkillsRoot(for: platform))
            XCTAssertTrue(pruneDirectories.contains { $0.path == root && $0.platform == platform },
                          "Missing \(platform) root from daemon prune list")
        }
    }

    func testEverySymlinkPlatformInBackfillCandidates() throws {
        let directories = DeployStateBackfill.userWideSymlinkDirectories(paths: paths.deployPaths)
        for platform in PlatformTarget.allCases where platform.usesSymlinks {
            let root = try XCTUnwrap(paths.deployPaths.userSkillsRoot(for: platform))
            XCTAssertTrue(
                directories.contains { $0.directory == root && $0.platform == platform },
                "Missing \(platform) root from deploy-state backfill candidates"
            )
        }
    }

    func testCursorHasNoUserSkillsRoot() {
        XCTAssertNil(paths.deployPaths.userSkillsRoot(for: .cursor))
        XCTAssertFalse(DeployReconciler.agentSkillDirs(paths: paths.deployPaths).contains {
            $0.path == PathConstants.cursorUserRulesDir
        })
        XCTAssertFalse(
            DeployStateBackfill.userWideSymlinkDirectories(paths: paths.deployPaths).contains { $0.platform == .cursor }
        )
    }

    func testPreExistingRootsUnchanged() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(paths.deployPaths.userSkillsRoot(for: .claudeCode), home + "/.claude/skills")
        XCTAssertEqual(paths.deployPaths.userSkillsRoot(for: .codex), home + "/.codex/skills")
        XCTAssertEqual(paths.deployPaths.userSkillsRoot(for: .openClaw), home + "/.openclaw/skills")
        XCTAssertEqual(paths.deployPaths.userSkillsRoot(for: .hermes), home + "/.hermes/skills/pensieve")
    }
}
