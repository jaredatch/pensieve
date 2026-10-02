import Foundation
import SwiftData

/// Tracks deploy/link history per platform for a skill.
@Model
final class DeployRecord {
    @Attribute(.unique) var id: UUID
    var skillID: UUID
    var platform: PlatformTarget
    var targetPath: String
    var deployedAt: Date
    var contentHash: String
    var projectID: UUID?

    init(skillID: UUID, platform: PlatformTarget, targetPath: String, contentHash: String, projectID: UUID? = nil) {
        self.id = UUID()
        self.skillID = skillID
        self.platform = platform
        self.targetPath = targetPath
        self.deployedAt = Date()
        self.contentHash = contentHash
        self.projectID = projectID
    }
}
