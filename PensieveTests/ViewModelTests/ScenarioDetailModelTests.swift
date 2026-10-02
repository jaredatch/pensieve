import SwiftData
import XCTest
@testable import Pensieve

private typealias PensieveCategory = Pensieve.Category

private final class RecordingScenarioReconciler: ScenarioReconcilerProtocol {
    var reconcileCalls = 0
    var result = BatchResult(outcomes: [
        BatchPairOutcome(skillID: UUID(), skillName: "Skill", platform: .claudeCode, error: nil)
    ])

    func reconcile(context: ModelContext) -> BatchResult {
        reconcileCalls += 1
        return result
    }
}

private struct AgentCall {
    let platform: PlatformTarget
    let scenarioID: UUID
    let enabled: Bool
}

private struct SkillCall {
    let slug: String
    let scenarioID: UUID
    let assigned: Bool
}

private final class RecordingScenarioStore: ScenarioStoreProtocol {
    var activatedScenarioIDs: [UUID] = []
    var deactivateCalls = 0
    var setAgentCalls: [AgentCall] = []
    var setSkillCalls: [SkillCall] = []

    func create(name: String, context: ModelContext, notifier: SyncStateNotifying) -> Scenario? { nil }
    func rename(_ scenario: Scenario, to name: String, context: ModelContext,
                notifier: SyncStateNotifying) {}
    func delete(_ scenario: Scenario, context: ModelContext, notifier: SyncStateNotifying) {}

    func delete(_ scenario: Scenario, reconciler: ScenarioReconcilerProtocol, context: ModelContext,
                notifier: SyncStateNotifying) -> BatchResult {
        reconciler.reconcile(context: context)
    }

    func setSkill(_ skill: Skill, inScenario scenario: Scenario, assigned: Bool, context: ModelContext,
                  notifier: SyncStateNotifying) {}

    func setSkill(_ skill: Skill, inScenario scenario: Scenario, assigned: Bool,
                  reconciler: ScenarioReconcilerProtocol, context: ModelContext,
                  notifier: SyncStateNotifying) -> BatchResult {
        setSkillCalls.append(SkillCall(slug: skill.directoryName, scenarioID: scenario.id, assigned: assigned))
        return reconciler.reconcile(context: context)
    }

    func setAgent(_ platform: PlatformTarget, inScenario scenario: Scenario, enabled: Bool, context: ModelContext,
                  notifier: SyncStateNotifying) {}

    func setAgent(_ platform: PlatformTarget, inScenario scenario: Scenario, enabled: Bool,
                  reconciler: ScenarioReconcilerProtocol, context: ModelContext,
                  notifier: SyncStateNotifying) -> BatchResult {
        setAgentCalls.append(AgentCall(platform: platform, scenarioID: scenario.id, enabled: enabled))
        return reconciler.reconcile(context: context)
    }

    func scenarios(containingSkillSlug slug: String, context: ModelContext) -> [Scenario] { [] }

    func activate(_ scenario: Scenario, reconciler: ScenarioReconcilerProtocol, context: ModelContext) -> BatchResult {
        activatedScenarioIDs.append(scenario.id)
        return reconciler.reconcile(context: context)
    }

    func deactivate(reconciler: ScenarioReconcilerProtocol, context: ModelContext) -> BatchResult {
        deactivateCalls += 1
        return reconciler.reconcile(context: context)
    }

    func reconcileAfterRemovingSkill(_ skill: Skill,
                                     reconciler: ScenarioReconcilerProtocol,
                                     context: ModelContext,
                                     notifier: SyncStateNotifying) -> BatchResult {
        reconciler.reconcile(context: context)
    }

    func activeScenarioID() -> UUID? { nil }
    func setActiveScenarioID(_ id: UUID?) {}
}

final class ScenarioDetailModelTests: XCTestCase {
    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self,
            IntentAssignment.self, DeployRecord.self, PensieveCategory.self, Scenario.self,
            ScenarioAssignment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @MainActor
    private func makeScenario(context: ModelContext) -> Scenario {
        let scenario = Scenario(name: "Writing")
        context.insert(scenario)
        return scenario
    }

    @MainActor
    private func makeSkill(context: ModelContext) -> Skill {
        let skill = Skill(name: "Skill", directoryName: "skill")
        context.insert(skill)
        return skill
    }

    private func makeModel(store: RecordingScenarioStore,
                           reconciler: RecordingScenarioReconciler) -> ScenarioDetailModel {
        ScenarioDetailModel(store: store, reconciler: reconciler)
    }

    @MainActor
    func testActivateDelegatesThroughStoreAndReconciler() throws {
        let context = try makeContext()
        let scenario = makeScenario(context: context)
        let store = RecordingScenarioStore()
        let reconciler = RecordingScenarioReconciler()
        let model = makeModel(store: store, reconciler: reconciler)

        model.activate(scenario, context: context)

        XCTAssertEqual(store.activatedScenarioIDs, [scenario.id])
        XCTAssertEqual(reconciler.reconcileCalls, 1)
        XCTAssertEqual(model.lastResult?.successes.count, 1)
        XCTAssertEqual(model.lastActionVerb, "deployed")
    }

    @MainActor
    func testDeactivateDelegatesThroughStoreAndReconciler() throws {
        let context = try makeContext()
        let store = RecordingScenarioStore()
        let reconciler = RecordingScenarioReconciler()
        let model = makeModel(store: store, reconciler: reconciler)

        model.deactivate(context: context)

        XCTAssertEqual(store.deactivateCalls, 1)
        XCTAssertEqual(reconciler.reconcileCalls, 1)
        XCTAssertEqual(model.lastResult?.successes.count, 1)
        XCTAssertEqual(model.lastActionVerb, "removed")
    }

    @MainActor
    func testSetAgentUsesReconcileAwareStoreOverload() throws {
        let context = try makeContext()
        let scenario = makeScenario(context: context)
        let store = RecordingScenarioStore()
        let reconciler = RecordingScenarioReconciler()
        let model = makeModel(store: store, reconciler: reconciler)

        model.setAgent(.cursor, inScenario: scenario, enabled: false, context: context)

        XCTAssertEqual(store.setAgentCalls.count, 1)
        XCTAssertEqual(store.setAgentCalls.first?.platform, .cursor)
        XCTAssertEqual(store.setAgentCalls.first?.scenarioID, scenario.id)
        XCTAssertEqual(store.setAgentCalls.first?.enabled, false)
        XCTAssertEqual(reconciler.reconcileCalls, 1)
        XCTAssertEqual(model.lastActionVerb, "removed")
    }

    @MainActor
    func testSetSkillUsesReconcileAwareStoreOverload() throws {
        let context = try makeContext()
        let scenario = makeScenario(context: context)
        let skill = makeSkill(context: context)
        let store = RecordingScenarioStore()
        let reconciler = RecordingScenarioReconciler()
        let model = makeModel(store: store, reconciler: reconciler)

        model.setSkill(skill, inScenario: scenario, assigned: true, context: context)

        XCTAssertEqual(store.setSkillCalls.count, 1)
        XCTAssertEqual(store.setSkillCalls.first?.slug, skill.directoryName)
        XCTAssertEqual(store.setSkillCalls.first?.scenarioID, scenario.id)
        XCTAssertEqual(store.setSkillCalls.first?.assigned, true)
        XCTAssertEqual(reconciler.reconcileCalls, 1)
        XCTAssertEqual(model.lastActionVerb, "deployed")
    }
}
