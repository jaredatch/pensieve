import Foundation

extension MachineStateService {
    static func projectRecords(_ projects: [Project], homeDirectory: String) -> [MachineStateProject] {
        let records = projects.compactMap { project -> MachineStateProject? in
            guard let key = project.identityKey, let kind = project.identityKind else { return nil }
            return MachineStateProject(
                identityKey: key,
                kind: kind,
                name: project.name,
                path: publishedPath(project.path, homeDirectory: homeDirectory)
            )
        }
        return Dictionary(records.map { ($0.identityKey, $0) }) { first, second in
            projectPrecedes(second, first) ? second : first
        }.map(\.value)
            .sorted { exactPrecedes($0.identityKey, $1.identityKey) }
    }

    static func publishedPath(_ path: String, homeDirectory: String) -> String? {
        HomePath.normalizedAbbreviation(path, homeDirectory: homeDirectory)
    }

    static func admittedPublishedPath(_ value: Any?) -> String? {
        guard let path = value as? String, path == "~" || path.hasPrefix("~/") else { return nil }
        guard !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return nil }
        return path
    }

    private static func projectPrecedes(_ lhs: MachineStateProject, _ rhs: MachineStateProject) -> Bool {
        if !exactlyEqual(lhs.name, rhs.name) { return exactPrecedes(lhs.name, rhs.name) }
        if !exactlyEqual(lhs.kind, rhs.kind) { return exactPrecedes(lhs.kind, rhs.kind) }
        switch (lhs.path, rhs.path) {
        case let (left?, right?): return exactPrecedes(left, right)
        case (.some, nil): return true
        case (nil, .some), (nil, nil): return false
        }
    }

    private static func exactlyEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static func exactPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
