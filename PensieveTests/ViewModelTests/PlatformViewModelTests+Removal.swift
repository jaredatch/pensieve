import SwiftData
import XCTest
@testable import Pensieve

extension PlatformViewModelTests {
    @MainActor
    func cleanupDeploys(_ vm: PlatformViewModel, skill: Skill, projects: [Project]) throws -> SkillCleanupResult {
        let context = ModelContext(try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
        return removeAllDeploysWithLocalEvidence(vm, skill: skill, projects: projects,
            context: context)
    }

    @MainActor
    func testRemoveAllDeploysDropsForeignCursorRecordWithoutRemovingRule() throws {
        let h = try WaitingRemovalHarness(platforms: [.cursor])
        defer { h.base.cleanup() }
        let path = h.vm.artifactPath(skill: h.base.skill, platform: .cursor, target: .userWide)
        try h.mapped.writeFile(at: path, content: "User's foreign rule")
        try h.base.deployState.upsert(DeployStateRecord(slug: h.base.skill.directoryName, platform: "cursor",
            scope: "user", projectIdentityKey: nil, artifactPath: path, recordedAt: "old"))
        let result = removeAllDeploysWithLocalEvidence(h.vm, skill: h.base.skill, projects: [],
            context: h.base.context).batch
        XCTAssertEqual(result.successes.count, 1)
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(try h.mapped.readFile(at: path), "User's foreign rule")
        XCTAssertTrue(try h.base.deployState.read().records.isEmpty)
    }

}
