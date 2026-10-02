import Foundation
import SwiftData

@MainActor
protocol PostSyncConverging {
    func run(after result: SyncCycleResult)
    func runAfterLaunchIngest()
}

/// Main-actor reconciliation after launch ingestion and successful resident sync cycles.
/// Deploy self-healing runs after every success; ledger-driven fan-out runs only when repository HEAD
/// advanced, using a newly-created context so sibling-context saves cannot be hidden by registered rows.
@MainActor
final class PostSyncConvergence: PostSyncConverging {
    typealias ContextFactory = @MainActor () -> ModelContext

    private let root: String
    private let deployReconciler: DeployReconciling
    private let contextFactory: ContextFactory
    private let categoryReconciler: CategoryReconcilerProtocol
    private let scenarioReconciler: ScenarioReconcilerProtocol
    private let intentReconciler: IntentReconcilerProtocol
    private let auditLog: (_ category: String, _ detail: String) -> Void
    /// Fires after each convergence pass; AppRuntime refreshes the deploy index here (PLAN-29).
    private let didConverge: () -> Void

    init(
        root: String = Constants.pensieveBaseDir,
        deployReconciler: DeployReconciling,
        contextFactory: @escaping ContextFactory,
        categoryReconciler: CategoryReconcilerProtocol,
        scenarioReconciler: ScenarioReconcilerProtocol,
        intentReconciler: IntentReconcilerProtocol,
        auditLog: @escaping (_ category: String, _ detail: String) -> Void = {
            SyncAudit().append(category: $0, detail: $1)
        },
        didConverge: @escaping () -> Void = {}
    ) {
        self.root = root
        self.deployReconciler = deployReconciler
        self.contextFactory = contextFactory
        self.categoryReconciler = categoryReconciler
        self.scenarioReconciler = scenarioReconciler
        self.intentReconciler = intentReconciler
        self.auditLog = auditLog
        self.didConverge = didConverge
    }

    func run(after result: SyncCycleResult) {
        guard case let .synced(_, _, _, headAdvanced) = result else { return }
        runSuccessfulCycle(runLedgerReconcilers: headAdvanced)
    }

    func runAfterLaunchIngest() {
        runSuccessfulCycle(runLedgerReconcilers: true)
    }

    private func runSuccessfulCycle(runLedgerReconcilers: Bool) {
        defer { didConverge() }
        do {
            let result = try deployReconciler.reconcile(root: root)
            auditLog("convergence", "deploy:\(result.prunedLinks):\(result.recompiledRules)")
        } catch {
            auditLog("convergence", "deployFailed")
        }

        guard runLedgerReconcilers else { return }
        let context = contextFactory()
        record(categoryReconciler.reconcile(context: context), name: "category")
        record(scenarioReconciler.reconcile(context: context), name: "scenario")
        record(intentReconciler.reconcile(context: context), name: "intent")
    }

    private func record(_ result: BatchResult, name: String) {
        auditLog("convergence", "\(name):\(result.successes.count):\(result.failureCount)")
    }
}
