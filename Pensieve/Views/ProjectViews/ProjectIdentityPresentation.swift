enum ProjectIdentityPresentation {
    static func symbol(for project: Project) -> String {
        switch ProjectIdentity.Kind(rawValue: project.identityKind ?? "") {
        case .remote:
            return "arrow.triangle.branch"
        case .marker:
            return "tag"
        case nil:
            return "questionmark.circle"
        }
    }

    static func label(for project: Project) -> String {
        switch ProjectIdentity.Kind(rawValue: project.identityKind ?? "") {
        case .remote:
            return "Git remote identity"
        case .marker:
            return "Marker identity"
        case nil:
            return "Identity pending"
        }
    }
}
