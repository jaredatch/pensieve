import Foundation
import XCTest
@testable import Pensieve

final class DeployPlatformCoverageTests: XCTestCase {
    func testEverySymlinkPlatformRootMatchesItsLinkPathParent() throws {
        for platform in PlatformTarget.allCases where platform.usesSymlinks {
            let root = try XCTUnwrap(DeployPaths.userSkillsRoot(for: platform))
            let linkPath = DeployPaths.linkPath(
                directoryName: "coverage-fixture",
                platform: platform,
                projectPath: nil
            )
            XCTAssertEqual(root, (linkPath as NSString).deletingLastPathComponent)
        }
    }

    func testEverySymlinkPlatformInDaemonPruneList() throws {
        let pruneDirectories = DeployReconciler.defaultAgentSkillDirs
        for platform in PlatformTarget.allCases where platform.usesSymlinks {
            let root = try XCTUnwrap(DeployPaths.userSkillsRoot(for: platform))
            XCTAssertTrue(pruneDirectories.contains { $0.path == root && $0.platform == platform },
                          "Missing \(platform) root from daemon prune list")
        }
    }

    func testEverySymlinkPlatformInBackfillCandidates() throws {
        let directories = DeployStateBackfill.userWideSymlinkDirectories(paths: .defaults)
        for platform in PlatformTarget.allCases where platform.usesSymlinks {
            let root = try XCTUnwrap(DeployPaths.userSkillsRoot(for: platform))
            XCTAssertTrue(
                directories.contains { $0.directory == root && $0.platform == platform },
                "Missing \(platform) root from deploy-state backfill candidates"
            )
        }
    }

    func testCursorHasNoUserSkillsRoot() {
        XCTAssertNil(DeployPaths.userSkillsRoot(for: .cursor))
        XCTAssertFalse(DeployReconciler.defaultAgentSkillDirs.contains { $0.path == PathConstants.cursorUserRulesDir })
        XCTAssertFalse(
            DeployStateBackfill.userWideSymlinkDirectories(paths: .defaults).contains { $0.platform == .cursor }
        )
    }

    func testPreExistingRootsUnchanged() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(DeployPaths.userSkillsRoot(for: .claudeCode), home + "/.claude/skills")
        XCTAssertEqual(DeployPaths.userSkillsRoot(for: .codex), home + "/.codex/skills")
        XCTAssertEqual(DeployPaths.userSkillsRoot(for: .openClaw), home + "/.openclaw/skills")
        XCTAssertEqual(DeployPaths.userSkillsRoot(for: .hermes), home + "/.hermes/skills/pensieve")
    }
}
