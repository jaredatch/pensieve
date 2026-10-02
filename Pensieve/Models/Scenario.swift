import Foundation
import SwiftData

@Model
final class Scenario {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    /// Member skills, stored by Skill.directoryName (the cross-machine join key).
    var skillSlugs: [String]
    /// Enabled agents, stored as PlatformTarget raw values so the set can sync through the manifest.
    var agentRawValues: [String]

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.skillSlugs = []
        self.agentRawValues = PlatformTarget.allCases.map(\.rawValue)
    }

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.skillSlugs = []
        self.agentRawValues = PlatformTarget.allCases.map(\.rawValue)
    }
}
