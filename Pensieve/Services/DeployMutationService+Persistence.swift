import Foundation
import SwiftData

extension DeployMutationService {
    func persistAndReconcile(
        localMachineID: String,
        context: ModelContext,
        reconcile: ((ModelContext) -> BatchResult)? = nil,
        mutation: () throws -> Bool
    ) throws -> IntentPersistence {
        try persist(
            reconcilesLocally: true, localMachineID: localMachineID,
            context: context, reconcile: reconcile, mutation: mutation
        )
    }

    func persistIntentOnly(
        localMachineID: String,
        context: ModelContext,
        mutation: () throws -> Bool
    ) throws {
        _ = try persist(
            reconcilesLocally: false, localMachineID: localMachineID,
            context: context, mutation: mutation
        )
    }

    private func persist(
        reconcilesLocally: Bool,
        localMachineID: String,
        context: ModelContext,
        reconcile: ((ModelContext) -> BatchResult)? = nil,
        mutation: () throws -> Bool
    ) throws -> IntentPersistence {
        let before = try remoteIntentKeys(localMachineID: localMachineID, context: context)
        let mutated = try mutation()
        guard mutated else {
            return IntentPersistence(mutated: false, reconciliation: BatchResult())
        }
        let after: Set<RemoteDeployKey>
        do {
            after = try remoteIntentKeys(localMachineID: localMachineID, context: context)
        } catch {
            context.rollback()
            throw error
        }
        do {
            try dependencies.writeManifest(context)
        } catch {
            context.rollback()
            throw error
        }
        do {
            try dependencies.saveContext(context)
        } catch {
            let saveError = error
            context.rollback()
            do {
                try dependencies.writeManifest(context)
            } catch {
                throw DeployIntentPersistenceError.manifestRestoreFailed(save: saveError, restore: error)
            }
            throw saveError
        }
        for key in before.subtracting(after) {
            recordRemoteChange(selected: false, key: key)
        }
        for key in after.subtracting(before) {
            recordRemoteChange(selected: true, key: key)
        }
        let result = reconcilesLocally ? (reconcile ?? dependencies.reconcile)(context) : BatchResult()
        dependencies.notifier()
        return IntentPersistence(mutated: true, reconciliation: result)
    }

    func prepareSelection(skills: [Skill], context: ModelContext) throws {
        let selectedIDs = skills.map(\.persistentModelID)
        let rebuild = StoreRebuildService(manifestService: dependencies.manifestService, save: dependencies.saveContext)
        do {
            try StoreIngestState.rebuildIfNeeded(using: rebuild, root: dependencies.root, context: context)
        } catch {
            if let syncError = error as? SyncError, case .storeUnreadable = syncError { throw error }
            throw DeployIntentModelError.ingestPending
        }
        let selectedRows = FetchDescriptor<Skill>(predicate: #Predicate { selectedIDs.contains($0.persistentModelID) })
        let currentIDs = Set(try context.fetchIdentifiers(selectedRows))
        guard Set(selectedIDs).isSubset(of: currentIDs) else { throw DeployIntentModelError.selectionChanged }
    }

    private func remoteIntentKeys(
        localMachineID: String,
        context: ModelContext
    ) throws -> Set<RemoteDeployKey> {
        Set(try context.fetch(FetchDescriptor<MachineDeployIntent>()).map(RemoteDeployKey.init))
            .filter { $0.machineID != localMachineID }
    }

    func realizeSelection(
        _ selected: Bool,
        skills: [Skill],
        platforms: [PlatformTarget],
        target: DeployTarget,
        reconciliation: BatchResult,
        context: ModelContext
    ) -> BatchResult {
        var result = BatchResult()
        result.readFailures = reconciliation.readFailures
        let expectedTarget = BatchPairTarget(target)
        let indexed = reconciliation.outcomesByPair
        var removals: [DeployRemovalPair] = []
        for skill in skills {
            for platform in platforms {
                let key = BatchPairKey(skillID: skill.id, platform: platform, target: expectedTarget)
                let outcome = indexed[key]
                if let outcome, !outcome.isSkipped {
                    result.outcomes.append(outcome)
                } else if !selected, reconciliation.retiredPairs.contains(key) {
                    continue
                } else if !selected, let outcome {
                    result.outcomes.append(outcome)
                } else if selected {
                    if !platformVM.isDeployed(skill: skill, platform: platform, target: target) {
                        result.append(platformVM.deployBatch(
                            skills: [skill], platforms: [platform], target: target, context: context
                        ))
                    }
                } else {
                    removals.append(DeployRemovalPair(skill: skill, platform: platform))
                }
            }
        }
        if !removals.isEmpty { result.append(platformVM.removeSelection(pairs: removals, target: target)) }
        return result
    }
}

struct IntentPersistence {
    let mutated: Bool
    let reconciliation: BatchResult
}
