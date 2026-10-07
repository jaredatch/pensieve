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
    var identityLine: String { ListRows.identityLine(key: displayIdentityKey, kind: kind) }
    var skillCount: Int { Set(machines.flatMap { $0.deploys.map(\.skillSlug) }).count }

    static func onlyOnOtherMacs(
        states: [MachineState], localProjectIdentityKeys: Set<String>, localMachineID: String?,
        now: @escaping () -> Date = Date.init
    ) -> [Self] {
        // Without this Mac's identity, its old publication cannot safely be classified as remote.
        guard let localMachineID else { return [] }
        let otherMacs = states.filter { $0.machineID != localMachineID }.map { state in
            (state, MachineDetailModel(state: state, localProjectIdentityKeys: localProjectIdentityKeys,
                                      localMachineID: localMachineID, now: now))
        }.sorted { ($0.1.name, $0.1.machineID) < ($1.1.name, $1.1.machineID) }
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
                    name: existing?.name ?? project.name, machines: (existing?.machines ?? []) + [machine]
                )
            }
        }
        return projects.values.sorted { ($0.name, $0.identityKey) < ($1.name, $1.identityKey) }
    }
}
