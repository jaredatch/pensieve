import Foundation

extension DeploymentsPresentation {
    struct IntentFact: Hashable {
        let machineID: String
        let platform: PlatformTarget
        let projectKey: String?
    }

    struct MachineSection: Equatable, Identifiable {
        let id: String
        let name: String
        let description: String
        let emptyText: String?
        let rows: [PlatformRow]
    }

    struct RemoteContent: Equatable {
        let machines: [MachineSection]
        let projects: [ProjectRow]
    }

    static func intentFacts(_ rows: [MachineDeployIntent], skillSlug: String) -> Set<IntentFact> {
        Set(rows.compactMap { row in
            guard row.skillSlug == skillSlug,
                  let platform = PlatformTarget(rawValue: row.platformRaw) else { return nil }
            return IntentFact(machineID: row.machineID, platform: platform, projectKey: row.projectKey)
        })
    }

    static func remoteContent(
        skillSlug: String,
        machineStates: [MachineState],
        localMachineID: String?,
        intents: Set<IntentFact>,
        heldRetractions: Set<RemoteDeployKey>
    ) -> RemoteContent {
        guard let localMachineID else { return RemoteContent(machines: [], projects: []) }
        let facts = RemoteFacts(intents: intents, heldRetractions: heldRetractions)
        let states = machineStates.filter { $0.machineID != localMachineID }.map {
            RemoteMachine($0, skillSlug: skillSlug)
        }
            .sorted(by: remoteMachinePrecedes)
        let machines = states.map { machine -> MachineSection in
            let rows = remoteMachineRows(skillSlug: skillSlug, machine: machine, facts: facts)
            return MachineSection(
                id: machine.state.machineID,
                name: machine.name,
                description: "Every project on \(machine.name). Changes apply the next time it syncs.",
                emptyText: rows.isEmpty ? noAgents : nil,
                rows: rows
            )
        }
        let projects = states.flatMap { machine in
            remoteProjects(skillSlug: skillSlug, machine: machine, facts: facts)
        }
        return RemoteContent(machines: machines, projects: projects)
    }

    static func sortedProjectRows(_ rows: [ProjectRow]) -> [ProjectRow] {
        rows.sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            let lhsMachine = projectMachineSortKey(lhs.id)
            let rhsMachine = projectMachineSortKey(rhs.id)
            if lhsMachine != rhsMachine { return lhsMachine < rhsMachine }
            let ownerOrder = (lhs.ownerName ?? "").localizedStandardCompare(rhs.ownerName ?? "")
            if ownerOrder != .orderedSame { return ownerOrder == .orderedAscending }
            return String(describing: lhs.id) < String(describing: rhs.id)
        }
    }
}

private extension DeploymentsPresentation {
    struct RemoteMachine {
        let state: MachineState
        let name: String
        let publishedDeploys: Set<PublishedDeploy>

        init(_ state: MachineState, skillSlug: String) {
            self.state = state
            name = PublishedStringSanitizer.name(state.name, fallback: "Mac")
            let userWide = state.userDeploys.compactMap { deploy -> PublishedDeploy? in
                guard deploy.slug == skillSlug,
                      let platform = PlatformTarget(rawValue: deploy.platform) else { return nil }
                return PublishedDeploy(platform: platform, projectKey: nil)
            }
            let projects = state.projectDeploys.compactMap { deploy -> PublishedDeploy? in
                guard deploy.slug == skillSlug,
                      let platform = PlatformTarget(rawValue: deploy.platform) else { return nil }
                return PublishedDeploy(platform: platform, projectKey: deploy.projectKey)
            }
            publishedDeploys = Set(userWide + projects)
        }
    }

    struct PublishedDeploy: Hashable {
        let platform: PlatformTarget
        let projectKey: String?
    }

    struct RemoteFacts {
        let intents: Set<IntentFact>
        let heldRetractions: Set<RemoteDeployKey>
    }

    struct RemoteRowState {
        let isOn: Bool
        let isEnabled: Bool
        let showsPublishedNote: Bool
    }

    static func remoteMachinePrecedes(_ lhs: RemoteMachine, _ rhs: RemoteMachine) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        return order == .orderedSame ? lhs.state.machineID < rhs.state.machineID : order == .orderedAscending
    }

    static func remoteMachineRows(
        skillSlug: String,
        machine: RemoteMachine,
        facts: RemoteFacts
    ) -> [PlatformRow] {
        let platforms = Set(machine.state.agents.compactMap(PlatformTarget.init(rawValue:)))
        return PlatformTarget.allCases.filter(platforms.contains).map { platform in
            remoteRow(
                skillSlug: skillSlug, machine: machine, platform: platform, projectKey: nil,
                inherited: false, facts: facts
            )
        }
    }

    static func remoteProjects(
        skillSlug: String,
        machine: RemoteMachine,
        facts: RemoteFacts
    ) -> [ProjectRow] {
        let platforms = Set(machine.state.agents.compactMap(PlatformTarget.init(rawValue:)))
        let supported = PlatformTarget.allCases.filter { platforms.contains($0) && $0.supportsProjectScope }
        let wholeMacStates = Dictionary(uniqueKeysWithValues: supported.map { platform in
            (platform, remoteState(
                skillSlug: skillSlug, machine: machine, platform: platform, projectKey: nil,
                facts: facts
            ))
        })
        var seen: Set<String> = []
        return machine.state.projects.compactMap { project -> ProjectRow? in
            guard ManifestService.isAdmittedProjectKey(project.identityKey),
                  seen.insert(project.identityKey).inserted else { return nil }
            let name = PublishedStringSanitizer.projectName(project.name, identityKey: project.identityKey)
            let path = project.path.map(PublishedStringSanitizer.path)
            let caption = path.flatMap { $0.isEmpty ? nil : machine.name + " · " + $0 } ?? machine.name
            let rows = supported.map { platform -> PlatformRow in
                return remoteRow(
                    skillSlug: skillSlug, machine: machine, platform: platform,
                    projectKey: project.identityKey, inherited: wholeMacStates[platform]?.isOn == true,
                    facts: facts
                )
            }
            return ProjectRow(
                id: .remote(machineID: machine.state.machineID, projectKey: project.identityKey),
                name: name,
                caption: caption,
                ownerName: machine.name,
                platforms: rows
            )
        }
    }

    static func remoteRow(
        skillSlug: String,
        machine: RemoteMachine,
        platform: PlatformTarget,
        projectKey: String?,
        inherited: Bool,
        facts: RemoteFacts
    ) -> PlatformRow {
        if inherited {
            return PlatformRow(
                platform: platform, isOn: true, inherited: true, isEnabled: false,
                note: "On for every project on \(machine.name)"
            )
        }
        let state = remoteState(
            skillSlug: skillSlug, machine: machine, platform: platform, projectKey: projectKey,
            facts: facts
        )
        return PlatformRow(
            platform: platform,
            isOn: state.isOn,
            isEnabled: state.isEnabled,
            note: state.showsPublishedNote ? "Turned on from \(machine.name)" : nil
        )
    }

    static func remoteState(
        skillSlug: String,
        machine: RemoteMachine,
        platform: PlatformTarget,
        projectKey: String?,
        facts: RemoteFacts
    ) -> RemoteRowState {
        let heldKey = RemoteDeployKey(
            machineID: machine.state.machineID, skillSlug: skillSlug,
            platformRaw: platform.rawValue, projectKey: projectKey
        )
        let intent = IntentFact(machineID: machine.state.machineID, platform: platform, projectKey: projectKey)
        if facts.intents.contains(intent) {
            return RemoteRowState(isOn: true, isEnabled: true, showsPublishedNote: false)
        }
        if facts.heldRetractions.contains(heldKey) {
            return RemoteRowState(isOn: false, isEnabled: true, showsPublishedNote: false)
        }
        let published = machine.publishedDeploys.contains(
            PublishedDeploy(platform: platform, projectKey: projectKey)
        )
        return published
            ? RemoteRowState(isOn: true, isEnabled: false, showsPublishedNote: true)
            : RemoteRowState(isOn: false, isEnabled: true, showsPublishedNote: false)
    }

    static func projectMachineSortKey(_ id: DeploymentProjectID) -> String {
        switch id {
        case .local:
            "0"
        case .remote:
            "1"
        }
    }
}
