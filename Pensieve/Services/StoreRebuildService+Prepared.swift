import SwiftData

/// Value-only output from a save's native rebuild. Its context never saves into the shared store:
/// the main actor applies these values with edits submitted while the disk scan was running.
struct PreparedStoreRebuild {
    struct SkillIdentity {
        let slug: String
        let name: String
        let description: String
    }
    var snapshot: ManifestSnapshot
    let skills: [SkillIdentity]
}

extension StoreRebuildService {
    func prepare(snapshot: ManifestSnapshot, fromRoot root: String, container: ModelContainer,
                 manifest: ManifestSnapshotting) throws -> PreparedStoreRebuild {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        // Reuse the convergent rebuild without committing its potentially superseded projection.
        let preview = StoreRebuildService(fileService: fileService, manifestService: manifest, save: { _ in })
        _ = preview.rebuild(snapshot: snapshot, fromRoot: root, context: context)
        return PreparedStoreRebuild(snapshot: try manifest.snapshot(from: context),
            skills: try context.fetch(FetchDescriptor<Skill>()).map {
                PreparedStoreRebuild.SkillIdentity(slug: $0.directoryName, name: $0.name, description: $0.skillDescription)
            })
    }

    /// No filesystem work here. Preserve row identity and volatile caches while accepting resolved
    /// frontmatter and the current overlay. Pending creates absent from the earlier scan stay local.
    func accept(_ prepared: PreparedStoreRebuild, snapshot: ManifestSnapshot, context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<Skill>())
        let bySlug = Dictionary(existing.map { ($0.directoryName, $0) }, uniquingKeysWith: { first, _ in first })
        let identities = Dictionary(prepared.skills.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        let slugs = Set(snapshot.skills.map(\.slug))
        var result = RebuildResult()
        for overlay in snapshot.skills {
            guard let identity = identities[overlay.slug] else { continue }
            let parsed = ParsedSkill(name: identity.name, description: identity.description, tags: [], body: "")
            upsertSkill(slug: overlay.slug, parsed: parsed, overlay: overlay,
                existing: bySlug[overlay.slug], context: context, result: &result)
        }
        for row in existing where !slugs.contains(row.directoryName) { context.delete(row) }
        rebuildCategories(snapshot: snapshot, context: context, result: &result)
        rebuildDeployIntents(snapshot: snapshot, context: context, result: &result)
        try save(context)
    }
}
