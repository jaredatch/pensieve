import Foundation

/// Captured under sync.lock before the folder moves. Unknown dates never authorize a takeover.
struct ManifestSkillRename {
    let original: SkillOverlay
    let leftoverCreatedAt: Date?
    let takesLeftovers: Bool
    var undo: SkillRenameUndo?

    func matchesLeftover(_ target: SkillOverlay) -> Bool {
        guard takesLeftovers, let leftoverCreatedAt, leftoverCreatedAt != Date(timeIntervalSince1970: 0),
              target.createdAt != Date(timeIntervalSince1970: 0) else { return false }
        var observed = target
        observed.createdAt = leftoverCreatedAt
        return ManifestService.sameCreation(observed, target)
    }
}

extension ManifestChange {
    func renameTargetIsTaken(_ target: SkillOverlay, old: String, details: ManifestSkillRename?,
                             in snapshot: ManifestSnapshot) -> Bool {
        if details?.matchesLeftover(target) == true { return false }
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
