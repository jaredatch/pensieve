import Foundation
import SwiftData

/// Per-platform realized-state ledger for machine deploy intent on this Mac.
@Model
final class IntentAssignment {
    @Attribute(.unique) var key: String
    var skillID: UUID
    var platformRaw: String
    var projectID: UUID?

    init(skillID: UUID, platformRaw: String, projectID: UUID? = nil) {
        self.key = Self.makeKey(skillID: skillID, platformRaw: platformRaw, projectID: projectID)
        self.skillID = skillID
        self.platformRaw = platformRaw
        self.projectID = projectID
    }

    static func makeKey(skillID: UUID, platformRaw: String, projectID: UUID?) -> String {
        let userWideKey = skillID.uuidString + "|" + platformRaw
        guard let projectID else { return userWideKey }
        return userWideKey + "|" + projectID.uuidString
    }
}
