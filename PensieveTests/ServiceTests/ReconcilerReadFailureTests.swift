import Foundation
import SwiftData
import XCTest
@testable import Pensieve

private enum ReconcileRead: CaseIterable {
    case intents
    case skills
    case intentLedger
    case scenarioLedger
    case categoryLedger
    case projects
}

private struct ReconcileReadFailure: Error {}

private struct FailingReconcilerStateFetcher: ReconcilerStateFetching {
    let failedRead: ReconcileRead
    private let live = ReconcilerStateFetcher()

    func deployIntents(context: ModelContext) throws -> [MachineDeployIntent] {
        if failedRead == .intents { throw ReconcileReadFailure() }
        return try live.deployIntents(context: context)
    }

    func skills(context: ModelContext) throws -> [Skill] {
        if failedRead == .skills { throw ReconcileReadFailure() }
        return try live.skills(context: context)
    }

    func intentAssignments(context: ModelContext) throws -> [IntentAssignment] {
        if failedRead == .intentLedger { throw ReconcileReadFailure() }
        return try live.intentAssignments(context: context)
    }

    func scenarioAssignments(context: ModelContext) throws -> [ScenarioAssignment] {
        if failedRead == .scenarioLedger { throw ReconcileReadFailure() }
        return try live.scenarioAssignments(context: context)
    }

    func categoryAssignments(context: ModelContext) throws -> [SkillProjectAssignment] {
        if failedRead == .categoryLedger { throw ReconcileReadFailure() }
        return try live.categoryAssignments(context: context)
    }

    func projects(context: ModelContext) throws -> [Project] {
        if failedRead == .projects { throw ReconcileReadFailure() }
        return try live.projects(context: context)
    }
}

@MainActor
final class ReconcilerReadFailureTests: XCTestCase {
    func testEveryIntentReconcilerReadFailureChangesNothingAtEitherScope() throws {
        for failedRead in ReconcileRead.allCases {
            let harness = try ProjectIntentHarness(
                installed: [.codex],
                stateFetcher: FailingReconcilerStateFetcher(failedRead: failedRead)
            )
            let skill = try harness.insertSkill("read-failure")
            let project = try harness.insertProject(
                name: "Project", path: "/projects/\(failedRead)", key: "key"
            )
            harness.platformVM.deploy(
                skill: skill, platform: .codex, target: .userWide, context: harness.context
            )
            harness.platformVM.deploy(
                skill: skill, platform: .codex, target: .project(project), context: harness.context
            )
            harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: "codex"))
            harness.context.insert(IntentAssignment(
                skillID: skill.id, platformRaw: "codex", projectID: project.id
            ))
            try harness.context.save()
            harness.linkService.unlinkCalls.removeAll()

            let result = harness.reconciler.reconcile(context: harness.context)

            XCTAssertTrue(result.hasFailures, "failed read: \(failedRead)")
            XCTAssertTrue(result.failures.isEmpty, "failed read: \(failedRead)")
            XCTAssertFalse(result.readFailures.first?.message.isEmpty ?? true, "failed read: \(failedRead)")
            XCTAssertTrue(harness.linkService.unlinkCalls.isEmpty, "failed read: \(failedRead)")
            XCTAssertEqual(try harness.assignments().count, 2, "failed read: \(failedRead)")
            XCTAssertEqual(harness.fileService.symlinks.count, 2, "failed read: \(failedRead)")
        }
    }

    func testCategoryIntentLedgerReadFailureDoesNotRemoveOrChangeLedger() throws {
        let fetcher = FailingReconcilerStateFetcher(failedRead: .intentLedger)
        let harness = try ProjectIntentHarness(installed: [.codex], stateFetcher: fetcher)
        let skill = try harness.insertSkill("category-read")
        let project = try harness.insertProject(name: "Project", path: "/projects/category-read", key: "key")
        harness.platformVM.deploy(
            skill: skill, platform: .codex, target: .project(project), context: harness.context
        )
        harness.context.insert(SkillProjectAssignment(
            skillID: skill.id, projectID: project.id, platform: .codex
        ))
        try harness.context.save()
        harness.linkService.unlinkCalls.removeAll()
        let reconciler = CategoryReconciler(platformVM: harness.platformVM, stateFetcher: fetcher)

        let result = reconciler.reconcile(context: harness.context)

        XCTAssertTrue(result.hasFailures)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(result.readFailures.first?.message.isEmpty ?? true)
        XCTAssertTrue(harness.linkService.unlinkCalls.isEmpty)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 1)
        XCTAssertEqual(harness.fileService.symlinks.count, 1)
    }

    func testRemovingProjectStopsWhenCategoryIntentLedgerReadFails() throws {
        let harness = try ProjectIntentHarness(installed: [.codex])
        let skill = try harness.insertSkill("category-remove-read")
        let project = try harness.insertProject(
            name: "Project", path: "/projects/category-remove-read", key: "category-key"
        )
        let category = Category(name: "Category")
        category.skillSlugs = [skill.directoryName]
        category.projectKeys = ["category-key"]
        harness.context.insert(category)
        try harness.context.save()
        let liveReconciler = CategoryReconciler(platformVM: harness.platformVM)
        XCTAssertFalse(liveReconciler.reconcile(context: harness.context).hasFailures)
        let fetcher = FailingReconcilerStateFetcher(failedRead: .intentLedger)

        let result = removeRegisteredProject(
            project,
            categoryStore: CategoryStore(),
            reconciler: CategoryReconciler(platformVM: harness.platformVM, stateFetcher: fetcher),
            platformVM: harness.platformVM, localMachineID: ProjectIntentHarness.localID,
            context: harness.context
        )

        XCTAssertTrue(result.hasFailures)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(result.readFailures.first?.message.isEmpty ?? true)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<Project>()), 1)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 1)
        XCTAssertTrue(harness.fileService.symlinks.contains(
            harness.artifactPath(skill: skill, platform: .codex, project: project)
        ))
    }

    func testRemovingProjectReportsItsIntentLedgerReadFailure() throws {
        let harness = try ProjectIntentHarness(installed: [.codex])
        let skill = try harness.insertSkill("unregister-read")
        let project = try harness.insertProject(
            name: "Project", path: "/projects/unregister-read", key: "key"
        )
        let category = Category(name: "Category")
        category.skillSlugs = [skill.directoryName]
        category.projectKeys = ["key"]
        harness.context.insert(category)
        try harness.context.save()
        let reconciler = CategoryReconciler(platformVM: harness.platformVM)
        XCTAssertFalse(reconciler.reconcile(context: harness.context).hasFailures)
        let artifactPath = harness.artifactPath(skill: skill, platform: .codex, project: project)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 1)
        XCTAssertTrue(harness.fileService.symlinks.contains(artifactPath))
        let fetcher = FailingReconcilerStateFetcher(failedRead: .intentLedger)

        let result = removeRegisteredProject(
            project,
            categoryStore: CategoryStore(),
            reconciler: reconciler,
            stateFetcher: fetcher,
            platformVM: harness.platformVM, localMachineID: ProjectIntentHarness.localID,
            context: harness.context
        )

        XCTAssertTrue(result.hasFailures)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(result.readFailures.first?.message.isEmpty ?? true)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<Project>()), 1)
        XCTAssertEqual(category.projectKeys, ["key"])
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 1)
        XCTAssertTrue(harness.fileService.symlinks.contains(artifactPath))
    }
}
