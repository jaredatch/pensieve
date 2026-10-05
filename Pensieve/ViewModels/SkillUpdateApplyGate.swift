import Foundation
import Observation

/// Process-owned reservations outlive either presentation. Release only after the apply worker returns.
@MainActor
@Observable
final class SkillUpdateApplyGate {
    private var skillIDs: Set<UUID> = []

    func isApplying(_ skillID: UUID) -> Bool { skillIDs.contains(skillID) }
    var hasReservations: Bool { !skillIDs.isEmpty }
    func begin(_ skillID: UUID) -> Bool { skillIDs.insert(skillID).inserted }
    func end(_ skillID: UUID) { skillIDs.remove(skillID) }
}
