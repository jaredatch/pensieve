import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class IntentReconcilerOwnershipLifecycleTests: XCTestCase {
    func testCategoryAndIntentEachLeaveArtifactForTheOtherOwner() throws {
        let harness = try ProjectIntentHarness(installed: [.codex])
        let skill = try harness.insertSkill("two-owners")
        let project = try harness.insertProject(name: "Project", path: "/projects/shared", key: "shared-key")
        let category = Category(name: "Shared")
        category.skillSlugs = [skill.directoryName]
        category.projectKeys = ["shared-key"]
        harness.context.insert(category)
        let intent = try harness.insertIntent(skill: skill, platformRaw: "codex", projectKey: "shared-key")
        let categoryReconciler = CategoryReconciler(platformVM: harness.platformVM)
        _ = categoryReconciler.reconcile(context: harness.context)
        _ = harness.reconciler.reconcile(context: harness.context)
        harness.linkService.unlinkCalls.removeAll()

        harness.context.delete(intent)
        try harness.context.save()
        _ = harness.reconciler.reconcile(context: harness.context)

        XCTAssertTrue(harness.linkService.unlinkCalls.isEmpty)
        XCTAssertTrue(try harness.assignments().isEmpty)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 1)
        XCTAssertTrue(harness.fileService.symlinks.contains(
            harness.artifactPath(skill: skill, platform: .codex, project: project)
        ))

        _ = try harness.insertIntent(skill: skill, platformRaw: "codex", projectKey: "shared-key")
        _ = harness.reconciler.reconcile(context: harness.context)
        category.skillSlugs = []
        try harness.context.save()
        _ = categoryReconciler.reconcile(context: harness.context)

        XCTAssertTrue(harness.linkService.unlinkCalls.isEmpty)
        XCTAssertEqual(try harness.assignments().count, 1)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 0)
        XCTAssertTrue(harness.fileService.symlinks.contains(
            harness.artifactPath(skill: skill, platform: .codex, project: project)
        ))

        for row in try harness.intents() where row.projectKey == "shared-key" {
            harness.context.delete(row)
        }
        try harness.context.save()
        _ = harness.reconciler.reconcile(context: harness.context)
        XCTAssertEqual(harness.linkService.unlinkCalls.count, 1)
        XCTAssertFalse(harness.fileService.symlinks.contains(
            harness.artifactPath(skill: skill, platform: .codex, project: project)
        ))
    }

    func testUnregisterDropsOnlyThatProjectsLedgerAndReregisterConverges() throws {
        let harness = try ProjectIntentHarness(installed: [.codex])
        let skill = try harness.insertSkill("reregister")
        let first = try harness.insertProject(name: "First", path: "/projects/first", key: "shared-key")
        let second = try harness.insertProject(name: "Second", path: "/projects/second", key: "shared-key")
        _ = try harness.insertIntent(skill: skill, platformRaw: "codex", projectKey: "shared-key")
        _ = harness.reconciler.reconcile(context: harness.context)
        harness.linkService.linkCalls.removeAll()

        let result = removeRegisteredProject(
            first,
            reconciler: NoopProjectCategoryReconciler(), manifestRoot: TestPaths.storeRoot,
            platformVM: harness.platformVM,
            localMachineID: ProjectIntentHarness.localID,
            context: harness.context
        )

        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(harness.linkService.unlinkCalls.map(\.projectPath), [first.path])
        XCTAssertEqual(try harness.assignments().map(\.projectID), [second.id])
        XCTAssertFalse(harness.fileService.symlinks.contains(
            harness.artifactPath(skill: skill, platform: .codex, project: first)
        ))
        XCTAssertEqual(try harness.intents().count, 1)

        let replacement = Project(name: "First Again", path: first.path)
        replacement.identityKey = "shared-key"
        registerProject(
            replacement, manifestRoot: TestPaths.storeRoot,
            context: harness.context,
            intentReconciler: harness.reconciler.reconcile
        )

        XCTAssertEqual(harness.linkService.linkCalls.map(\.projectPath), [replacement.path])
        XCTAssertEqual(Set(try harness.assignments().compactMap(\.projectID)), Set([second.id, replacement.id]))
        XCTAssertEqual(try harness.assignments().count, 2)
        XCTAssertEqual(harness.fileService.symlinks.count, 2)
    }

}
