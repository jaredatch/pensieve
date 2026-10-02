import SwiftData

extension DeployIntentModel {
    func recordRemoteChange(selected: Bool, key: RemoteDeployKey) {
        if selected {
            dependencies.remoteRetractions.recordIntent(key)
        } else {
            dependencies.remoteRetractions.recordRetraction(key)
        }
    }

    func reconcileRows(
        skills: [Skill],
        platforms: Set<PlatformTarget>,
        selectedMachineIDs: Set<String>,
        context: ModelContext
    ) throws -> Bool {
        let slugs = Set(skills.map(\.directoryName))
        let platformRaws = Set(platforms.map(\.rawValue))
        let rows = try context.fetch(FetchDescriptor<MachineDeployIntent>())
        var existingKeys = Set(rows.filter { $0.projectKey == nil }.map(\.key))
        var mutated = false
        for row in rows where row.projectKey == nil
            && slugs.contains(row.skillSlug) && platformRaws.contains(row.platformRaw) {
            guard !selectedMachineIDs.contains(row.machineID) else { continue }
            context.delete(row)
            existingKeys.remove(row.key)
            mutated = true
        }
        for machineID in selectedMachineIDs {
            for skill in skills {
                for platform in platforms {
                    let key = MachineDeployIntent.makeKey(
                        machineID: machineID, skillSlug: skill.directoryName,
                        platformRaw: platform.rawValue, projectKey: nil
                    )
                    guard existingKeys.insert(key).inserted else { continue }
                    context.insert(MachineDeployIntent(
                        machineID: machineID,
                        skillSlug: skill.directoryName,
                        platformRaw: platform.rawValue
                    ))
                    mutated = true
                }
            }
        }
        return mutated
    }
}
