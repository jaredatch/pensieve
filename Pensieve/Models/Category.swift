import Foundation
import SwiftData

@Model
final class Category {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    /// Member projects, stored by the cross-machine-stable Project.identityKey, NOT local Project.id.
    var projectKeys: [String]
    /// Assigned skills (the standing rule), stored by Skill.directoryName (the cross-machine join key).
    var skillSlugs: [String]

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.projectKeys = []
        self.skillSlugs = []
    }
}
