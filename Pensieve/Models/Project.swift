import Foundation
import SwiftData

@Model
final class Project {
    @Attribute(.unique) var id: UUID
    var name: String
    var path: String
    var identityKey: String?
    var identityKind: String?
    var createdAt: Date

    init(name: String, path: String) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.createdAt = Date()
    }
}
