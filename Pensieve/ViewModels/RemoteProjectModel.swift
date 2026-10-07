import Foundation

/// Published projects stay presentation values. Their paths never become local registrations.
struct RemoteProjectModel: Identifiable {
    struct Machine: Identifiable {
        let detail: MachineDetailModel
        let publishedPath: String?
        let deploys: [MachineDetailModel.DeploySummary]

        var id: String { detail.machineID }
    }

    let identityKey: String
    let kind: String
    let name: String
    let machines: [Machine]

    var id: String { identityKey }
    var displayIdentityKey: String { PublishedStringSanitizer.path(identityKey) }
    var identityLine: String {
        switch ProjectIdentity.Kind(rawValue: kind) {
        case .remote: displayIdentityKey
        case .marker: "Marker identity"
        case nil: "Unknown identity"
        }
    }
    var skillCount: Int { Set(machines.flatMap { $0.deploys.map(\.skillSlug) }).count }

    /// A local registration takes precedence even while the window's remote snapshot is stale.
    static func excludingLocalProjects(_ cachedProjects: [Self], localProjectIdentityKeys: Set<String>) -> [Self] {
        cachedProjects.filter { !localProjectIdentityKeys.contains($0.identityKey) }
    }

    static func onlyOnOtherMacs(
        states: [MachineState], localProjectIdentityKeys: Set<String>, localMachineID: String?,
        now: @escaping () -> Date = Date.init
    ) -> [Self] {
        // Without this Mac's identity, its old publication cannot safely be classified as remote.
        guard let localMachineID else { return [] }
        // A stable machine ID supplies metadata regardless of unrelated publishes or Mac renames.
        let otherMacs = states.filter { $0.machineID != localMachineID }.sorted { $0.machineID < $1.machineID }.map { state in
            (state, MachineDetailModel(state: state, localProjectIdentityKeys: localProjectIdentityKeys,
                                      localMachineID: localMachineID, now: now))
        }
        var projects: [String: Self] = [:]
        for (state, detail) in otherMacs {
            for project in detail.onlyOnMachineProjects {
                let path = state.projects.first { $0.identityKey == project.identityKey }?.path
                let machine = Machine(
                    detail: detail,
                    publishedPath: path.map(PublishedStringSanitizer.path),
                    deploys: detail.projectDeploys.filter { $0.projectKey == project.identityKey }
                )
                let existing = projects[project.identityKey]
                projects[project.identityKey] = Self(
                    identityKey: project.identityKey, kind: existing?.kind ?? project.kind,
                    name: existing?.name ?? project.name,
                    machines: (existing?.machines ?? []) + [machine]
                )
            }
        }
        return projects.values.map { project in
            Self(identityKey: project.identityKey, kind: project.kind, name: project.name,
                 machines: project.machines.sorted { ($0.detail.name, $0.id) < ($1.detail.name, $1.id) })
        }.sorted { ($0.name, $0.identityKey) < ($1.name, $1.identityKey) }
    }
}
