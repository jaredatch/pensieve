import Foundation

enum ProjectRegistration {
    static func makeProject(
        name: String,
        path: String,
        using identityService: ProjectIdentityServiceProtocol = ProjectIdentityService()
    ) throws -> Project {
        let identity = try identityService.identity(forProjectAt: path)
        let project = Project(name: name, path: path)
        project.identityKey = identity.key
        project.identityKind = identity.kind.rawValue
        return project
    }
}
