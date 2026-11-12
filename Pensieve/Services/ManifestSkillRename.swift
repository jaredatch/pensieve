import Foundation

/// Captured under sync.lock before the folder moves. Unknown dates never authorize a takeover.
struct ManifestSkillRename {
    let original: SkillOverlay
    let leftoverCreatedAt: Date?
    let takesLeftovers: Bool

    func matchesLeftover(_ target: SkillOverlay) -> Bool {
        guard takesLeftovers, let leftoverCreatedAt, leftoverCreatedAt != Date(timeIntervalSince1970: 0),
              target.createdAt != Date(timeIntervalSince1970: 0) else { return false }
        var observed = target
        observed.createdAt = leftoverCreatedAt
        return ManifestService.sameCreation(observed, target)
    }
}
