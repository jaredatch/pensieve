import Foundation
import SwiftData

/// Publish the durable request withdrawal before touching project artifacts. Registration and
/// realized ledgers remain live until cleanup finishes. No changed facts means no save or publish.
struct ProjectRemovalWithdrawalRequest {
    let keepingSharedKey: Bool
    let intents: [MachineDeployIntent]
    let localMachineID: String?
}

struct ProjectRemovalWithdrawal {
    let manifestService: ManifestSnapshotting?
    let manifestRoot: String
    let logFailure: (String) -> Void

    func apply(project: Project, request: ProjectRemovalWithdrawalRequest, context: ModelContext) throws {
        guard !request.keepingSharedKey, let key = project.identityKey else { return }
        let categories = try context.fetch(FetchDescriptor<Category>()).filter { $0.projectKeys.contains(key) }
        let memberships = categories.map { (category: $0, keys: $0.projectKeys) }
        let withdrawing = request.intents.filter { $0.machineID == request.localMachineID && $0.projectKey == key }
        let facts = withdrawing.map {
            DeployIntentRecord(machineID: $0.machineID, skillSlug: $0.skillSlug,
                               platformRaw: $0.platformRaw, projectKey: $0.projectKey)
        }
        guard !categories.isEmpty || !withdrawing.isEmpty else { return }
        for category in categories { category.projectKeys.removeAll { $0 == key } }
        for intent in withdrawing { context.delete(intent) }
        do {
            try save(context: context)
        } catch {
            context.rollback()
            repairManifest(context: context)
            throw failure("save project withdrawal", error)
        }
        do {
            try publish(context: context)
        } catch {
            let publicationError = error
            var restoration = "The saved withdrawal was restored."
            do {
                for membership in memberships { membership.category.projectKeys = membership.keys }
                for fact in facts {
                    context.insert(MachineDeployIntent(machineID: fact.machineID, skillSlug: fact.skillSlug,
                        platformRaw: fact.platformRaw, projectKey: fact.projectKey))
                }
                try save(context: context)
            } catch {
                context.rollback()
                restoration = "The withdrawal remains saved."
                logFailure("Couldn't restore project withdrawal: " + error.localizedDescription)
            }
            repairManifest(context: context)
            throw failure("publish project withdrawal. " + restoration, publicationError)
        }
    }

    func save(context: ModelContext) throws {
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

    private func failure(_ operation: String, _ error: Error) -> NSError {
        NSError(domain: "ProjectRemoval", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't " + operation + ": " + error.localizedDescription])
    }
}
