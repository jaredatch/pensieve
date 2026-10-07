import SwiftData
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    @MainActor
    func testSkillDeletionRetiresArtifactsInOneStateWrite() throws {
        let harness = try contextAndVM()
        let project = reviewProject(harness.context)
        let targets: [(PlatformTarget, DeployTarget)] = [(.claudeCode, .userWide), (.codex, .project(project)),
                                                        (.cursor, .project(project))]
        for (platform, target) in targets {
            let path = artifactPath(platform, project: target.project?.path)
            try plant(owned: true, legacy: false, platform: platform, path: path, project: target.project?.path)
            try reviewRecord(harness.state, path: path, platform: platform, target: target)
        }
        var writes = 0
        mapped.beforeDeployStateWrite = { _ in writes += 1 }
        let library = SkillLibraryViewModel(skillStore: store, fileService: mapped,
            manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest")
        XCTAssertTrue(SkillDeletionFlow.delete(skill: skill, library: library, platformVM: harness.vm,
            projects: [project], context: harness.context))
        XCTAssertEqual(writes, 1, "Skill deletion retires its records in one durable batch")
        XCTAssertTrue(try harness.state.read().records.isEmpty)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<Skill>()), 0)
        for (platform, target) in targets {
            XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(
                at: artifactPath(platform, project: target.project?.path)))
        }
    }

    @MainActor
    func testSelectionClassifiesEachArtifactOnce() throws {
        let harness = try contextAndVM()
        let project = reviewProject(harness.context)
        for platform in [PlatformTarget.claudeCode, .cursor] {
            let path = artifactPath(platform, project: project.path)
            try plant(owned: true, legacy: false, platform: platform, path: path, project: project.path)
            try reviewRecord(harness.state, path: path, platform: platform, target: .project(project))
        }
        var linkReads = 0, ruleReads = 0
        mapped.beforeSymlinkRead = { _ in linkReads += 1 }
        mapped.beforeRuleRead = { _ in ruleReads += 1 }
        let result = harness.vm.removeSelection(skills: [skill], platforms: [.claudeCode, .cursor], target: .project(project))
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(result.successes.count, 2)
        XCTAssertEqual(linkReads, 1, "An owned link is classified once in the removal batch")
        XCTAssertEqual(ruleReads, 1, "A marked rule is classified once in the removal batch")
        XCTAssertTrue(try harness.state.read().records.isEmpty)
        for platform in [PlatformTarget.claudeCode, .cursor] {
            XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: artifactPath(platform, project: project.path)))
        }
    }
}
