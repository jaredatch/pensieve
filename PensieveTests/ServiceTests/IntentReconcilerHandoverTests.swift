import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class IntentReconcilerHandoverTests: XCTestCase {
    func testCompletionStopsReadingLegacyOwnershipAndAllowsRetraction() throws {
        let harness = try ProjectIntentHarness(installed: [.codex])
        let skill = try harness.insertSkill("legacy-owner")
        harness.platformVM.deploy(skill: skill, platform: .codex, target: .userWide, context: harness.context)
        harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: "codex"))
        harness.context.insert(ScenarioAssignment(skillID: skill.id, platform: .codex))
        try harness.context.save()
        let fetcher = LegacyOwnershipFetcher()
        var complete = false
        let reconciler = IntentReconciler(
            platformVM: harness.platformVM,
            machineIdentity: ProjectIntentIdentityStub(id: ProjectIntentHarness.localID),
            stateFetcher: fetcher,
            handoverIsComplete: { complete }
        )

        XCTAssertFalse(reconciler.reconcile(context: harness.context).hasFailures)
        XCTAssertEqual(fetcher.reads, 1)
        XCTAssertTrue(harness.linkService.unlinkCalls.isEmpty)
        XCTAssertEqual(harness.fileService.symlinks.count, 1)
        XCTAssertTrue(try harness.assignments().isEmpty)

        harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: "codex"))
        try harness.context.save()
        complete = true
        fetcher.fail = true
        XCTAssertFalse(reconciler.reconcile(context: harness.context).hasFailures)
        XCTAssertEqual(fetcher.reads, 1, "completed handover must never fetch the legacy ledger")
        XCTAssertEqual(harness.linkService.unlinkCalls.count, 1)
        XCTAssertTrue(harness.fileService.symlinks.isEmpty)
        XCTAssertTrue(try harness.assignments().isEmpty)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<ScenarioAssignment>()), 1)
    }
}

private final class LegacyOwnershipFetcher: ReconcilerStateFetching {
    var reads = 0
    var fail = false
    private let live = ReconcilerStateFetcher()

    func scenarioAssignments(context: ModelContext) throws -> [ScenarioAssignment] {
        reads += 1
        if fail { throw DeployStubFailure() }
        return try live.scenarioAssignments(context: context)
    }
    func deployIntents(context: ModelContext) throws -> [MachineDeployIntent] {
        try live.deployIntents(context: context)
    }
    func skills(context: ModelContext) throws -> [Skill] { try live.skills(context: context) }
    func intentAssignments(context: ModelContext) throws -> [IntentAssignment] {
        try live.intentAssignments(context: context)
    }
    func categoryAssignments(context: ModelContext) throws -> [SkillProjectAssignment] {
        try live.categoryAssignments(context: context)
    }
    func projects(context: ModelContext) throws -> [Project] { try live.projects(context: context) }
}
