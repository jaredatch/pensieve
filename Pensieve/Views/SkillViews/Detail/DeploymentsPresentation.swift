import Foundation

enum DeploymentProjectID: Hashable {
    case local(UUID)
    case remote(machineID: String, projectKey: String)
}

/// The Deployments tab's rows from the snapshot — pure, so the inherited-state rule, the marks, and the
/// copy are tested apart from SwiftUI (the frames `Skills / Details — Deployments (no projects)` and
/// `(projects)`; `spec-2026-09-16.md` decisions 12–14).
enum DeploymentsPresentation {
    struct MacSection: Equatable {
        let rows: [PlatformRow]
        let emptyText: String?
    }

    struct PlatformRow: Equatable, Identifiable {
        let platform: PlatformTarget
        let isOn: Bool
        let inherited: Bool
        let isEnabled: Bool
        let note: String?
        var id: String { platform.rawValue }

        init(
            platform: PlatformTarget,
            isOn: Bool,
            inherited: Bool = false,
            isEnabled: Bool = true,
            note: String? = nil
        ) {
            self.platform = platform
            self.isOn = isOn
            self.inherited = inherited
            self.isEnabled = isEnabled
            self.note = note
        }
    }

    struct ProjectRow: Equatable, Identifiable {
        let id: DeploymentProjectID
        let name: String
        let caption: String
        let ownerName: String?
        let platforms: [PlatformRow]
        /// The bare marks a collapsed row shows: every platform on here, its own or inherited.
        var deployedPlatforms: [PlatformTarget] { platforms.filter(\.isOn).map(\.platform) }
        var summary: String? { deployedPlatforms.isEmpty ? "Not deployed" : nil }
    }

    static let thisMacDescription = "Turn on a platform to make this skill available in every project on this Mac."
    static let projectsDescription = "Turn on a platform for one project only. Works alongside This Mac."
    static let noProjects = "No projects yet."
    static let noAgents = "No supported agents detected"
    static let everyProjectTitle = "Deployed to Every Project"
    static let oneProjectTitle = "Deployed to One Project"
    static let noSkillsDeployed = "No skills deployed"

    static func machineDeploySummary(everyProject: Int, oneProject: Int) -> String {
        ListRows.counted(everyProject, "skill") + " for every project · "
            + "\(oneProject) for one project"
    }

    static func macRows(
        installed: [PlatformTarget],
        status: [PlatformTarget: Bool],
        statusIsCurrent: Bool = true
    ) -> [PlatformRow] {
        installed.map {
            PlatformRow(platform: $0, isOn: status[$0] ?? false, isEnabled: statusIsCurrent)
        }
    }

    static func macSection(
        installed: [PlatformTarget],
        status: [PlatformTarget: Bool],
        statusIsCurrent: Bool = true
    ) -> MacSection {
        let rows = macRows(installed: installed, status: status, statusIsCurrent: statusIsCurrent)
        return macSection(rows: rows)
    }

    static func macSection(rows: [PlatformRow]) -> MacSection {
        MacSection(rows: rows, emptyText: rows.isEmpty ? noAgents : nil)
    }

    static func projectRows(projects: [Project], projectPlatforms: [PlatformTarget],
                            macStatus: [PlatformTarget: Bool], projectStatus: [UUID: [PlatformTarget: Bool]],
                            homeDirectory: String, statusIsCurrent: Bool = true,
                            prefixesThisMac: Bool = false) -> [ProjectRow] {
        projects.map { project in
            let own = projectStatus[project.id] ?? [:]
            let rows = projectPlatforms.map { platform -> PlatformRow in
                let inherited = macStatus[platform] ?? false
                return PlatformRow(
                    platform: platform,
                    isOn: inherited || (own[platform] ?? false),
                    inherited: inherited,
                    isEnabled: statusIsCurrent && !inherited,
                    note: inherited ? "On for every project on this Mac" : nil
                )
            }
            let path = ListRows.abbreviatePath(project.path, homeDirectory: homeDirectory)
            return ProjectRow(
                id: .local(project.id),
                name: project.name,
                caption: prefixesThisMac ? "This Mac · " + path : path,
                ownerName: nil,
                platforms: rows
            )
        }
    }
}
