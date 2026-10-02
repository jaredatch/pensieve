import Foundation

enum DeployTarget: Hashable {
    case userWide
    case project(Project)

    var project: Project? {
        if case .project(let project) = self {
            return project
        } else {
            return nil
        }
    }
}
