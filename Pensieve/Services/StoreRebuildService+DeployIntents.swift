import SwiftData

extension StoreRebuildService {
    func rebuildDeployIntents(
        snapshot: ManifestSnapshot,
        context: ModelContext,
        result: inout RebuildResult
    ) {
        let existing = (try? context.fetch(FetchDescriptor<MachineDeployIntent>())) ?? []
        var existingByKey = Dictionary(existing.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        for record in snapshot.deployIntents {
            let key = MachineDeployIntent.makeKey(
                machineID: record.machineID,
                skillSlug: record.skillSlug,
                platformRaw: record.platformRaw,
                projectKey: record.projectKey
            )
            if let row = existingByKey.removeValue(forKey: key) {
                var changed = false
                if row.machineID != record.machineID { row.machineID = record.machineID; changed = true }
                if row.skillSlug != record.skillSlug { row.skillSlug = record.skillSlug; changed = true }
                if row.platformRaw != record.platformRaw { row.platformRaw = record.platformRaw; changed = true }
                if row.projectKey != record.projectKey { row.projectKey = record.projectKey; changed = true }
                if changed { result.deployIntentsUpdated += 1 }
            } else {
                context.insert(MachineDeployIntent(
                    machineID: record.machineID,
                    skillSlug: record.skillSlug,
                    platformRaw: record.platformRaw,
                    projectKey: record.projectKey
                ))
                result.deployIntentsInserted += 1
            }
        }

        for row in existingByKey.values {
            context.delete(row)
            result.deployIntentsRemoved += 1
        }
    }
}
