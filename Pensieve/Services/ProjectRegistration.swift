import Foundation
import SwiftData

enum ProjectRegistration {
    private static let registrationLock = NSLock()

    static func submissionPath(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    static func makeProject(
        name: String,
        path: String,
        using identityService: ProjectIdentityServiceProtocol = ProjectIdentityService(),
        files: FileServiceProtocol = FileService()
    ) throws -> Project {
        try files.requireProjectDirectory(at: path)
        let identity = identityService.peekIdentity(forProjectAt: path)
        let project = Project(name: name, path: path)
        project.identityKey = identity?.key
        project.identityKind = identity?.kind.rawValue
        return project
    }

    /// Both entry points hold the same lock from the duplicate lookup through the marker and save.
    /// The caller owns its context on this thread; no actor hop occurs inside the transaction.
    static func register(_ project: Project, context: ModelContext, files: FileServiceProtocol,
                         identityService: ProjectIdentityServiceProtocol,
                         save: (Project) throws -> PersistentIdentifier) throws -> (id: PersistentIdentifier, didSave: Bool) {
        try registrationLock.withLock {
            let resolved = files.realPath(at: project.path)
            let existing = try context.fetch(FetchDescriptor<Project>()).filter {
                files.realPath(at: $0.path) == resolved
            }
            if let existing = existing.sorted(by: { $0.id.uuidString < $1.id.uuidString }).first {
                return (existing.persistentModelID, false)
            }
            let id = try identityService.withIdentity(forProjectAt: project.path) { identity in
                project.identityKey = identity.key
                project.identityKind = identity.kind.rawValue
                return try save(project)
            }
            return (id, true)
        }
    }
}
