import Foundation
import SwiftData

/// Per-agent realized-state ledger for scenario-managed user-wide assignments.
@Model
final class ScenarioAssignment {
    @Attribute(.unique) var id: UUID
    var skillID: UUID
    var platform: PlatformTarget
    var assignedAt: Date

    init(skillID: UUID, platform: PlatformTarget) {
        self.id = UUID()
        self.skillID = skillID
        self.platform = platform
        self.assignedAt = Date()
    }
}
