import Foundation
import SwiftData

/// Publish this Mac's intent withdrawal before touching project artifacts. Shared category rules
/// stay unchanged. Registration and realized ledgers remain live until cleanup finishes.
/// Every attempt publishes the saved snapshot.
struct ProjectRemovalWithdrawalRequest {
    let keepingSharedKey: Bool
    let intents: [MachineDeployIntent]
    let localMachineID: String?
}

struct ProjectRemovalWithdrawal {
    let manifestService: ManifestSnapshotting?
    let manifestRoot: String
    let logFailure: (String) -> Void

    func apply(project: Project, request: ProjectRemovalWithdrawalRequest, context: ModelContext) throws -> Bool {
        let key = project.identityKey
        let withdrawing = request.intents.filter {
            !request.keepingSharedKey && key != nil && $0.machineID == request.localMachineID && $0.projectKey == key
        }
        let facts = withdrawing.map {
            DeployIntentRecord(machineID: $0.machineID, skillSlug: $0.skillSlug,
                               platformRaw: $0.platformRaw, projectKey: $0.projectKey)
        }
        let changed = !withdrawing.isEmpty
        for intent in withdrawing { context.delete(intent) }
        do {
            if context.hasChanges { try context.save() }
        } catch {
            context.rollback()
            repairManifest(context: context)
            throw failure("save project withdrawal", error)
        }
        do {
            try publish(context: context)
        } catch {
            let publicationError = error
            var restoration = "The saved requests were kept."
            var withdrawalRemainsSaved = false
            do {
                if changed {
                    try restore(facts: facts, context: context)
                    restoration = "The saved withdrawal was restored."
                }
            } catch {
                context.rollback()
                restoration = "The withdrawal remains saved."
                withdrawalRemainsSaved = changed
                logFailure("Couldn't restore project withdrawal: " + error.localizedDescription)
            }
            repairManifest(context: context)
            throw failure("publish project withdrawal", publicationError, detail: restoration,
                          didWithdrawRequests: withdrawalRemainsSaved)
        }
        return changed
    }

    private func restore(facts: [DeployIntentRecord], context: ModelContext) throws {
        for fact in facts {
            context.insert(MachineDeployIntent(machineID: fact.machineID, skillSlug: fact.skillSlug,
                platformRaw: fact.platformRaw, projectKey: fact.projectKey))
        }
        try context.save()
    }

    func repairManifest(context: ModelContext) {
        do {
            try publish(context: context)
        } catch {
            logFailure("Couldn't rewrite the project manifest from the saved store: " + error.localizedDescription)
        }
    }

    private func publish(context: ModelContext) throws {
        guard let manifestService else { return }
        try manifestService.write(manifestService.snapshot(from: context), toRoot: manifestRoot)
    }

    private func failure(_ operation: String, _ error: Error, detail: String? = nil,
                         didWithdrawRequests: Bool = false) -> ProjectRemovalWithdrawalFailure {
        let reason = error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return ProjectRemovalWithdrawalFailure(message: "Couldn't " + operation + ": " + reason
            + (detail.map { ". " + $0 } ?? ""), didWithdrawRequests: didWithdrawRequests)
    }
}

struct ProjectRemovalWithdrawalFailure: LocalizedError {
    let message: String
    let didWithdrawRequests: Bool
    var errorDescription: String? { message }
}
