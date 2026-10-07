import XCTest
@testable import Pensieve

final class DeployIndexTests: XCTestCase {
    func testSummaryNamesPlatformsInCaseOrderWithScopes() {
        let index = DeployIndex(records: [
            record(slug: "alpha", platform: .codex, scope: "user", path: "/user/codex"),
            record(slug: "alpha", platform: .claudeCode, scope: "project", key: "a", path: "/a/claude"),
            record(slug: "alpha", platform: .claudeCode, scope: "project", key: "b", path: "/b/claude")
        ])

        XCTAssertEqual(index.summary(for: "alpha"), "Claude Code, Codex · This Mac, 2 projects")
    }

    func testSummaryKeepsUnknownPlatformRawValue() {
        let indexed = DeployIndex(records: [rawRecord(platform: "zed", key: "a")])
        let noKey = DeployIndex(records: [rawRecord(platform: "zed", key: nil)])

        XCTAssertEqual(indexed.summary(for: "alpha"), "zed · 1 project")
        XCTAssertEqual(noKey.summary(for: "alpha"), "zed · 1 project")
    }

    func testSummaryNotDeployedAndUnavailable() {
        XCTAssertEqual(DeployIndex.empty.summary(for: "missing"), "Not deployed")
        XCTAssertEqual(DeployIndex.unavailable.summary(for: "missing"), "Deploy state unavailable")
        XCTAssertFalse(DeployIndex.unavailable.available)
    }

    func testSkillCountInProjectKeyCountsDistinctSlugs() {
        let index = DeployIndex(records: [
            record(slug: "alpha", platform: .claudeCode, scope: "project", key: "a", path: "/a/1"),
            record(slug: "alpha", platform: .codex, scope: "project", key: "a", path: "/a/2"),
            record(slug: "beta", platform: .claudeCode, scope: "project", key: "a", path: "/a/3")
        ])

        XCTAssertEqual(index.skillCount(inProjectKey: "a"), 2)
        XCTAssertEqual(index.skillCount(inProjectKey: "b"), 0)
    }

    func testKeylessProjectRecordsCountAsProjectsNotThisMac() {
        let index = DeployIndex(records: [
            record(slug: "alpha", platform: .codex, scope: "project", path: "/checkout/agents/alpha.md"),
            record(slug: "alpha", platform: .claudeCode, scope: "project", path: "/checkout/.claude/skills/alpha"),
            record(slug: "beta", platform: .cursor, scope: "project", path: "/checkout/.cursor/rules/beta.mdc"),
            record(slug: "alpha", platform: .codex, scope: "project", path: "/checkout-other/agents/alpha.md")
        ])
        XCTAssertEqual(index.summary(for: "alpha"), "Claude Code, Codex · 2 projects")
        XCTAssertEqual(index.summary(for: "beta"), "Cursor · 1 project")
        XCTAssertEqual(index.skillCount(inProjectKey: "/checkout"), 2)
        XCTAssertEqual(index.skillCount(inProjectKey: "/checkout-other"), 1)
        XCTAssertEqual(index.skillCount(inProjectKey: "/check"), 0)
    }

    func testIsDeployed() {
        let index = DeployIndex(records: [
            record(slug: "alpha", platform: .claudeCode, scope: "user", path: "/alpha")
        ])

        XCTAssertTrue(index.isDeployed(slug: "alpha"))
        XCTAssertFalse(index.isDeployed(slug: "beta"))
    }

    private func record(slug: String, platform: PlatformTarget, scope: String,
                        key: String? = nil, path: String) -> DeployStateRecord {
        DeployStateRecord(slug: slug, platform: platform.rawValue, scope: scope,
                          projectIdentityKey: key, artifactPath: path, recordedAt: "2026-09-07T00:00:00Z")
    }

    private func rawRecord(platform: String, key: String?) -> DeployStateRecord {
        DeployStateRecord(slug: "alpha", platform: platform, scope: "project",
                          projectIdentityKey: key, artifactPath: "/zed", recordedAt: "2026-09-07T00:00:00Z")
    }
}
