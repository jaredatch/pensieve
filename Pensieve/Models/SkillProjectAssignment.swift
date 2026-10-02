import Foundation
import SwiftData

/// Per-agent realized-state ledger for category-managed project assignments.
@Model
final class SkillProjectAssignment {
    @Attribute(.unique) var id: UUID
    var skillID: UUID
    var projectID: UUID
    var platform: PlatformTarget
    var assignedAt: Date

    init(skillID: UUID, projectID: UUID, platform: PlatformTarget) {
        self.id = UUID()
        self.skillID = skillID
        self.projectID = projectID
        self.platform = platform
        self.assignedAt = Date()
    }
}
