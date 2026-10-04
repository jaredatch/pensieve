import Foundation
import SwiftData

/// Legacy per-agent ownership retained until this Mac completes the one-time handover.
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
