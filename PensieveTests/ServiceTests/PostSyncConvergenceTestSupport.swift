import Foundation
import SwiftData
@testable import Pensieve

final class ConvergenceRecorder {
    var events: [String] = []
    var contexts: [ObjectIdentifier] = []
    var observedCategoryNames: [String] = []
}

struct ConvergenceRecordingDeploy: DeployReconciling {
    let recorder: ConvergenceRecorder

    func reconcile(root: String) throws -> ReconcileOutcome {
        recorder.events.append("deploy")
        return ReconcileOutcome()
    }
}

struct ConvergenceRecordingLedger: CategoryReconcilerProtocol,
    IntentReconcilerProtocol {
    func reconcileRemovingProject(_ projectID: UUID, context: ModelContext) -> BatchResult {
        reconcile(context: context)
    }

    let name: String
    let recorder: ConvergenceRecorder

    func reconcile(context: ModelContext) -> BatchResult {
        recorder.events.append(name)
        recorder.contexts.append(ObjectIdentifier(context))
        if name == "category" {
            let categories = (try? context.fetch(FetchDescriptor<Pensieve.Category>())) ?? []
            recorder.observedCategoryNames.append(contentsOf: categories.map(\.name))
        }
        return BatchResult()
    }
}

struct ConvergenceNullAudit: SyncAuditWriting {
    func record(category: String, detail: String) {}
}
