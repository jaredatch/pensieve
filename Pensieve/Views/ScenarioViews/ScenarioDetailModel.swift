import Foundation
import SwiftData

@Observable
final class ScenarioDetailModel {
    private(set) var lastResult: BatchResult?
    private(set) var lastActionVerb = "deployed"

    private let store: ScenarioStoreProtocol
    private let reconciler: ScenarioReconcilerProtocol

    init(store: ScenarioStoreProtocol = ScenarioStore(), reconciler: ScenarioReconcilerProtocol) {
        self.store = store
        self.reconciler = reconciler
    }

    func activate(_ scenario: Scenario, context: ModelContext) {
        lastActionVerb = "deployed"
        lastResult = store.activate(scenario, reconciler: reconciler, context: context)
    }

    func deactivate(context: ModelContext) {
        lastActionVerb = "removed"
        lastResult = store.deactivate(reconciler: reconciler, context: context)
    }

    func setAgent(_ platform: PlatformTarget, inScenario scenario: Scenario, enabled: Bool, context: ModelContext) {
        lastActionVerb = enabled ? "deployed" : "removed"
        lastResult = store.setAgent(platform, inScenario: scenario, enabled: enabled, reconciler: reconciler, context: context)
    }

    func setSkill(_ skill: Skill, inScenario scenario: Scenario, assigned: Bool, context: ModelContext) {
        lastActionVerb = assigned ? "deployed" : "removed"
        lastResult = store.setSkill(skill, inScenario: scenario, assigned: assigned, reconciler: reconciler, context: context)
    }

    func rename(_ scenario: Scenario, to name: String, context: ModelContext) {
        store.rename(scenario, to: name, context: context)
    }
}
