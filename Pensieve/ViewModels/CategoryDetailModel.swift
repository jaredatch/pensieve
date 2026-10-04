import Foundation
import SwiftData

/// Thin @Observable wrapper the CategoryDetailView drives: each toggle mutates the rule, reconciles the
/// delta through the injected store + reconciler, and stores the resulting BatchResult so the view can
/// surface failures the §5 (BulkDeploySheet) way. Keeps the View declarative and the behavior testable. (PLAN-06 / 06.5)
@Observable
final class CategoryDetailModel {
    private(set) var lastResult: BatchResult?
    /// Past-tense verb for the result summary, set by the action taken (assign → "deployed", un-assign → "removed").
    private(set) var lastActionVerb = "deployed"

    private let store: CategoryStoreProtocol
    private let reconciler: CategoryReconcilerProtocol

    init(store: CategoryStoreProtocol = CategoryStore(), reconciler: CategoryReconcilerProtocol) {
        self.store = store
        self.reconciler = reconciler
    }

    func setSkill(_ skill: Skill, inCategory category: Category, assigned: Bool, context: ModelContext) {
        lastActionVerb = assigned ? "deployed" : "removed"
        let result = store.setSkill(skill, inCategory: category, assigned: assigned, reconciler: reconciler, context: context)
        lastResult = assigned ? result.reportingSkippedProjects() : result
    }

    func setProject(_ project: Project, inCategory category: Category, member: Bool, context: ModelContext) {
        lastActionVerb = member ? "deployed" : "removed"
        let result = store.setProject(project, inCategory: category, member: member, reconciler: reconciler, context: context)
        lastResult = member ? result.reportingSkippedProjects() : result
    }

    func rename(_ category: Category, to name: String, context: ModelContext) {
        store.rename(category, to: name, context: context)
    }
}
