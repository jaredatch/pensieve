import Foundation

/// Captured under sync.lock before the folder moves. Unknown dates never authorize a takeover.
struct ManifestSkillRename {
    let original: SkillOverlay
    let leftoverCreatedAt: Date?
    let takesLeftovers: Bool
    var undo: SkillRenameUndo?
    var requiresOwnedSource = false

    func matchesLeftover(_ target: SkillOverlay) -> Bool {
        guard takesLeftovers, let leftoverCreatedAt, leftoverCreatedAt != Date(timeIntervalSince1970: 0),
              target.createdAt != Date(timeIntervalSince1970: 0) else { return false }
        var observed = target
        observed.createdAt = leftoverCreatedAt
        return ManifestService.sameCreation(observed, target)
    }
}

extension ManifestChange {
    struct RefusedRename {
        let old: String
        let new: String
        let details: ManifestSkillRename
    }

    /// Use the save queue's disk judgment before sync can publish the moved row itself.
    func refusedRename(in snapshot: ManifestSnapshot) -> RefusedRename? {
        guard case .renameSkill(let old, let new, let details) = self, let details else { return nil }
        do {
            try validate(in: snapshot)
        } catch ManifestSaveError.renameTaken {
            return RefusedRename(old: old, new: new, details: details)
        } catch {
            return nil
        }
        return nil
    }

    func renameTargetIsTaken(_ target: SkillOverlay, old: String, details: ManifestSkillRename?,
                             in snapshot: ManifestSnapshot) -> Bool {
        if details?.matchesLeftover(target) == true { return false }
        if let details, details.requiresOwnedSource, ManifestService.sameCreation(details.original, target) { return false }
        if snapshot.skills.contains(where: { $0.slug == old }) { return true }
        guard let details else { return false }
        return !ManifestService.sameCreation(details.original, target)
    }

    /// Follow the local skill when a refused rename restores its previous folder.
    func retargetingSkill(from old: String, to new: String) -> ManifestChange {
        func slug(_ value: String) -> String { value == old ? new : value }
        switch self {
        case .skillMetadata(let target, let tags, let scope): return .skillMetadata(slug(target), tags, scope)
        case .categorySkill(let category, let target, let member): return .categorySkill(category, slug(target), member)
        case .deleteSkill(let target): return .deleteSkill(slug(target))
        case .retireSkill(let target): return .retireSkill(slug(target))
        case .retireLocalSkill(let target, let machine): return .retireLocalSkill(slug(target), machine)
        case .createCategory(var record):
            record.skillSlugs = record.skillSlugs.map(slug)
            return .createCategory(record)
        default: return self
        }
    }
}

extension RefusedCreateRecords.Rename {
    func isTaken(in snapshot: ManifestSnapshot) -> Bool {
        snapshot.skills.contains { $0.slug.lowercased() == new.lowercased() && !owns($0) }
    }

    func change(publishing current: SkillOverlay, as slug: String) -> ManifestChange {
        var details = ManifestSkillRename(original: current, leftoverCreatedAt: nil, takesLeftovers: false)
        details.requiresOwnedSource = true
        return .renameSkill(old, slug, details: details)
    }

    /// Absence and a different creation both mean this hold owns nothing under the old name.
    func retire(in snapshot: inout ManifestSnapshot, deleting: Bool) {
        guard snapshot.skills.contains(where: { $0.slug == old && owns($0) }) else { return }
        ManifestChange.retireSkill(old).apply(to: &snapshot)
        if deleting { ManifestChange.deleteSkill(old).apply(to: &snapshot) }
    }
}

extension ManifestChange {
    func renameOwnedSkill(_ old: String, to new: String, current: SkillOverlay,
                          in snapshot: inout ManifestSnapshot) -> Bool {
        let ownsOld = snapshot.skills.contains { $0.slug == old && ManifestService.sameCreation($0, current) }
        // An empty destination can still carry the departed peer's assignments.
        if !snapshot.skills.contains(where: { $0.slug == new && ManifestService.sameCreation($0, current) }) {
            clearRenameTarget(new, in: &snapshot)
        }
        if ownsOld {
            snapshot.skills.removeAll { $0.slug == old }
            for index in snapshot.deployIntents.indices where snapshot.deployIntents[index].skillSlug == old {
                snapshot.deployIntents[index].skillSlug = new
            }
            for index in snapshot.categories.indices {
                snapshot.categories[index].skillSlugs = snapshot.categories[index].skillSlugs.map { $0 == old ? new : $0 }
            }
        }
        var renamed = current
        renamed.slug = new
        snapshot.skills.removeAll { $0.slug == new }
        snapshot.skills.append(renamed)
        return true
    }

}
