import Foundation
import SwiftData

/// App-only snapshot protocol + conformance (PLAN-12 / 12.1). Refines `ManifestReadWriting` so a
/// caller that snapshots-then-writes keeps a single dependency. Excluded from the daemon target
/// (it imports SwiftData); the daemon consumes only `ManifestReadWriting`.
protocol ManifestSnapshotting: ManifestReadWriting {
    /// Project the SwiftData store into a portable snapshot. Throws on a SwiftData fetch failure so a
    /// read error is never silently written out as an empty, overlay-pruning manifest (08.4 review).
    func snapshot(from context: ModelContext) throws -> ManifestSnapshot
}

extension ManifestService: ManifestSnapshotting {
    func snapshot(from context: ModelContext) throws -> ManifestSnapshot {
        // NOT `try?`: a fetch failure must not collapse to an empty snapshot that gets committed + PUSHED
        // (a remote-wide deletion). (08.4 review)
        let skills = try context.fetch(FetchDescriptor<Skill>())
        let categories = try context.fetch(FetchDescriptor<Category>())
        let deployIntents = try context.fetch(FetchDescriptor<MachineDeployIntent>())

        let skillOverlays = skills.map { skill in
            let origin: SkillOrigin
            if skill.installedOriginData != nil {
                origin = .installed(skill.installedOrigin ?? .empty)
            } else if let importedFrom = skill.importedFrom {
                origin = .imported(from: importedFrom)
            } else {
                origin = .authored
            }
            return SkillOverlay(
                slug: skill.directoryName,
                createdAt: skill.createdAt,
                scope: skill.scope,
                tags: skill.tags,
                cursor: skill.cursorConfig,
                agents: [],
                origin: origin
            )
        }
        let categoryRecords = categories.map {
            CategoryRecord(name: $0.name, projectKeys: $0.projectKeys, skillSlugs: $0.skillSlugs)
        }
        // Project identities are per-machine and are published in `machines/<id>.yaml`
        // (`MachineStateService.projectRecords`); the manifest carries none, so `projects.yaml` is the
        // constant `projects:` on every machine and never ping-pongs between them.
        return ManifestSnapshot(
            schemaVersion: Self.currentSchemaVersion,
            categories: categoryRecords,

            projects: [],
            skills: skillOverlays,
            deployIntents: Self.deployIntentRecords(from: deployIntents)
        )
    }

    private static func deployIntentRecords(
        from rows: [MachineDeployIntent]
    ) -> [DeployIntentRecord] {
        rows.map {
            DeployIntentRecord(
                machineID: $0.machineID,
                skillSlug: $0.skillSlug,
                platformRaw: $0.platformRaw,
                projectKey: $0.projectKey
            )
        }
    }
}
