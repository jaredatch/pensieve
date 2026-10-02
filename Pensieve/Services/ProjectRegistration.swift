import Foundation

enum ProjectRegistration {
    static func makeProject(
        name: String,
        path: String,
        using identityService: ProjectIdentityServiceProtocol = ProjectIdentityService()
    ) -> Project {
        let project = Project(name: name, path: path)
        if let identity = try? identityService.identity(forProjectAt: path) {
            project.identityKey = identity.key
            project.identityKind = identity.kind.rawValue
        }
        return project
    }
}
