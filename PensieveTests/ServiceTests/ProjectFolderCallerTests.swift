import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ProjectFolderCallerTests: XCTestCase {
    func testDeploymentsAlertNamesMissingProjectAndKeepsDurableIntent() throws {
        let harness = try ProjectFolderCallerHarness()
        defer { harness.cleanup() }
        let model = harness.model()
        let result = try model.set(
            true, skill: harness.skill, platform: .codex, target: .project(harness.project), context: harness.context
        )
        XCTAssertEqual(result.failureCount, 1)
        XCTAssertTrue(model.error?.contains(harness.project.name) == true)
        XCTAssertTrue(model.error?.contains("folder is missing") == true)
        try assertMissingPairHasNoRecord(harness)
        let durable = try ManifestService(fileService: harness.files).read(fromRoot: harness.root + "/store").deployIntents
        XCTAssertEqual(durable.first?.projectKey, harness.project.identityKey)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
        try harness.files.createDirectory(at: harness.project.path)
        XCTAssertEqual(harness.intent.reconcile(context: harness.context).successes.count, 1)
        XCTAssertTrue(harness.files.isSymlink(at: harness.artifact(.codex)))
    }

    func testBulkSheetReportsMissingProjectAndOtherProjectIntentStillDeploys() throws {
        let harness = try ProjectFolderCallerHarness()
        defer { harness.cleanup() }
        try harness.addIntent(project: harness.otherProject)
        let model = harness.model()
        let outcome = try BulkDeploySheet.perform(
            .deploy, forProject: true, platformVM: harness.platformVM, intentModel: model,
            skills: [harness.skill], platforms: [.claudeCode, .grok, .codex, .cursor], target: .project(harness.project),
            machineIDs: [], context: harness.context
        )
        guard case .localDeploy(let result) = outcome else { return XCTFail("Expected local result") }
        XCTAssertEqual(result.failureCount, 4)
        for failure in result.failures {
            XCTAssertTrue(failure.error?.contains(harness.project.name) == true)
            XCTAssertTrue(failure.error?.contains("folder is missing") == true)
        }
        let records = try harness.context.fetch(FetchDescriptor<DeployRecord>())
        XCTAssertEqual(records.map(\.projectID), [harness.otherProject.id])
        XCTAssertTrue(harness.files.isSymlink(at: harness.artifact(.codex, project: harness.otherProject)))
        XCTAssertFalse(try harness.files.entryExistsWithoutFollowingLinks(at: harness.root + "/absent"))
        let durable = try ManifestService(fileService: harness.files).read(fromRoot: harness.root + "/store").deployIntents
        XCTAssertEqual(durable.filter { $0.projectKey == harness.project.identityKey }.count, 4)
    }

    func testCategoryFailureListNamesMissingProjectAndOtherPairsDeploy() throws {
        let harness = try ProjectFolderCallerHarness()
        defer { harness.cleanup() }
        let rule = try harness.addCategory()
        rule.skillSlugs = []
        rule.projectKeys.append(harness.otherProject.identityKey!)
        try harness.context.save()
        let store = CategoryStore(manifestService: ManifestService(fileService: harness.files),
                                  manifestRoot: harness.root + "/store")
        let model = CategoryDetailModel(store: store, reconciler: harness.category)
        model.setSkill(harness.skill, inCategory: rule, assigned: true, context: harness.context)
        let result = try XCTUnwrap(model.lastResult)
        XCTAssertEqual(result.failureCount, 4)
        XCTAssertEqual(result.successes.count, 4)
        for failure in result.failures {
            XCTAssertTrue(failure.error?.contains(harness.project.name) == true)
            XCTAssertTrue(failure.error?.contains("folder is missing") == true)
        }
        XCTAssertEqual(try harness.context.fetch(FetchDescriptor<DeployRecord>())
                           .map(\.projectID), Array(repeating: harness.otherProject.id, count: 4))
        let durable = try ManifestService(fileService: harness.files).read(fromRoot: harness.root + "/store").categories
        XCTAssertEqual(durable.first?.skillSlugs, [harness.skill.directoryName])
        XCTAssertFalse(try harness.files.entryExistsWithoutFollowingLinks(at: harness.root + "/absent"))
    }

    func testCategorySkillRemovalFromMissingProjectSucceedsWithoutShownError() throws {
        try assertCategoryRemovalFromMissingProject(removingSkill: true)
    }

    func testCategoryMemberRemovalFromMissingProjectSucceedsWithoutShownError() throws {
        try assertCategoryRemovalFromMissingProject(removingSkill: false)
    }

    func testRemovingIntentDeployAndRegisteredMissingProjectCreatesNothing() throws {
        let harness = try ProjectFolderCallerHarness()
        defer { harness.cleanup() }
        try harness.addIntent()
        harness.context.insert(IntentAssignment(skillID: harness.skill.id, platformRaw: "codex", projectID: harness.project.id))
        harness.context.insert(SkillProjectAssignment(skillID: harness.skill.id,
                                                       projectID: harness.project.id, platform: .cursor))
        let rule = try harness.addCategory()
        let model = harness.model()
        let result = try model.set(
            false, skill: harness.skill, platform: .codex, target: .project(harness.project), context: harness.context
        )
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 1)
        let removed = harness.platformVM.removeBatch(
            pairs: DeployRemovalPair.expand(skills: [harness.skill], platforms: [.claudeCode, .grok, .codex, .cursor]),
            target: .project(harness.project)
        )
        XCTAssertEqual(removed.successes.count, 4)
        let unregister = removeRegisteredProject(
            harness.project,
            reconciler: harness.category, manifestService: ManifestService(fileService: harness.files),
            manifestRoot: harness.root + "/store", platformVM: harness.platformVM,
            localMachineID: ProjectIntentHarness.localID,
            context: harness.context
        )
        XCTAssertFalse(unregister.hasFailures)
        XCTAssertEqual(try harness.context.fetch(FetchDescriptor<Project>()).map(\.id), [harness.otherProject.id])
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 0)
        XCTAssertFalse(rule.projectKeys.contains(harness.project.identityKey!))
        XCTAssertFalse(try harness.files.entryExistsWithoutFollowingLinks(at: harness.root + "/absent"))
    }

    private func assertCategoryRemovalFromMissingProject(removingSkill: Bool) throws {
        let harness = try ProjectFolderCallerHarness()
        defer { harness.cleanup() }
        let rule = try harness.addCategory()
        try harness.files.createDirectory(at: harness.project.path)
        XCTAssertEqual(harness.category.reconcile(context: harness.context).successes.count, 4)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 4)
        try harness.files.deleteDirectory(at: harness.root + "/absent")
        let model = CategoryDetailModel(
            store: CategoryStore(manifestService: ManifestService(fileService: harness.files),
                                 manifestRoot: harness.root + "/store"), reconciler: harness.category
        )
        if removingSkill {
            model.setSkill(harness.skill, inCategory: rule, assigned: false, context: harness.context)
        } else {
            model.setProject(harness.project, inCategory: rule, member: false, context: harness.context)
        }
        let result = try XCTUnwrap(model.lastResult)
        XCTAssertEqual(model.lastActionVerb, "removed")
        XCTAssertFalse(result.hasFailures, "A missing folder must not make removal present an error")
        XCTAssertTrue(result.failures.isEmpty, "The category view displays this failure list")
        XCTAssertEqual(result.skipped.count, 4)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 4)
        XCTAssertFalse(try harness.files.entryExistsWithoutFollowingLinks(at: harness.root + "/absent"))
        let durable = try ManifestService(fileService: harness.files).read(fromRoot: harness.root + "/store").categories
        XCTAssertEqual(durable.first?.skillSlugs, removingSkill ? [] : [harness.skill.directoryName])
        XCTAssertEqual(durable.first?.projectKeys, removingSkill ? [harness.project.identityKey!] : [])
    }

    private func assertMissingPairHasNoRecord(_ harness: ProjectFolderCallerHarness) throws {
        XCTAssertFalse(try harness.files.entryExistsWithoutFollowingLinks(at: harness.root + "/absent"))
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<DeployRecord>()), 0)
        XCTAssertTrue(try harness.deployState.read().records.isEmpty)
    }
}
