import Foundation
import SwiftData

struct DeployTargetCatalog {
    let machines: [DeployIntentMachine]
    let states: [MachineState]
    let intents: [MachineDeployIntent]

    var publishedNamesByID: [String: [String]] {
        Dictionary(states.map {
            let visible = PublishedStringSanitizer.name($0.name, fallback: "")
            return ($0.machineID, visible.isEmpty ? [] : [$0.name, visible])
        }, uniquingKeysWith: { first, _ in first })
    }
}

extension DeployMutationService {
    func targetCatalog(context: ModelContext, localID: String?) throws -> DeployTargetCatalog {
        let states = dependencies.stateService.readAll(fromRoot: dependencies.root)
        let stateByID = Dictionary(states.map { ($0.machineID, $0) }, uniquingKeysWith: { first, _ in first })
        let intents = try context.fetch(FetchDescriptor<MachineDeployIntent>())
        let intentIDs = Set(intents.compactMap { $0.projectKey == nil ? $0.machineID : nil })
        let allIDs = Set(stateByID.keys).union(intentIDs).union(localID.map { [$0] } ?? [])
        let machines = allIDs.map { machineID in
            let state = stateByID[machineID]
            var name = machineID == localID ? "This Mac" : state.map {
                PublishedStringSanitizer.name($0.name, fallback: "Mac")
            } ?? machineID
            if allIDs.contains(where: { $0 != machineID && $0.caseInsensitiveCompare(name) == .orderedSame }) {
                name += " (" + machineID + ")"
            }
            return DeployIntentMachine(
                id: machineID, name: name,
                isLocal: machineID == localID,
                isUnseen: machineID != localID && state == nil
            )
        }.sorted {
            if $0.isLocal != $1.isLocal { return $0.isLocal }
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.id < $1.id
        }
        return DeployTargetCatalog(machines: machines, states: states, intents: intents)
    }
}
