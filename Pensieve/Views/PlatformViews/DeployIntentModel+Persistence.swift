import SwiftData

extension DeployIntentModel {
    func persistAndReconcile(
        localMachineID: String,
        context: ModelContext,
        mutation: () throws -> Bool
    ) throws -> IntentPersistence {
        try persist(
            reconcilesLocally: true, localMachineID: localMachineID,
            context: context, mutation: mutation
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
        let result = reconcilesLocally ? dependencies.reconcile(context) : BatchResult()
        dependencies.notifier()
        return IntentPersistence(mutated: true, reconciliation: result)
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
        for skill in skills {
            for platform in platforms {
                let targetFailure = reconciliation.failures.first {
                    $0.skillID == skill.id && $0.platform == platform
                        && $0.target == expectedTarget
                }
                let targetSuccess = reconciliation.successes.first {
                    $0.skillID == skill.id && $0.platform == platform
                        && $0.target == expectedTarget
                }
                let isDeployed = platformVM.isDeployed(skill: skill, platform: platform, target: target)
                let artifactExists = platformVM.artifactExists(skill: skill, platform: platform, target: target)
                if let targetFailure {
                    result.outcomes.append(targetFailure)
                } else if (selected && isDeployed) || (!selected && !artifactExists) {
                    if let targetSuccess { result.outcomes.append(targetSuccess) }
                } else if selected {
                    result.append(platformVM.deployBatch(
                        skills: [skill], platforms: [platform], target: target, context: context
                    ))
                } else {
                    result.append(platformVM.removeBatch(
                        skills: [skill], platforms: [platform], target: target
                    ))
                }
            }
        }
        return result
    }
}

struct IntentPersistence {
    let mutated: Bool
    let reconciliation: BatchResult
}
