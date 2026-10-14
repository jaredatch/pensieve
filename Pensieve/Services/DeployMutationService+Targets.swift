import Foundation
import SwiftData

struct DeployTargetCatalog {
    let machines: [DeployIntentMachine]
    let states: [MachineState]
    let intents: [MachineDeployIntent]
}

extension DeployMutationService {
    func targetCatalog(context: ModelContext, localID: String) throws -> DeployTargetCatalog {
        let states = dependencies.stateService.readAll(fromRoot: dependencies.root)
        let stateByID = Dictionary(states.map { ($0.machineID, $0) }, uniquingKeysWith: { first, _ in first })
        let intents = try context.fetch(FetchDescriptor<MachineDeployIntent>())
        let intentIDs = Set(intents.compactMap { $0.projectKey == nil ? $0.machineID : nil })
        let allIDs = Set(stateByID.keys).union(intentIDs).union([localID])
        let machines = allIDs.map { machineID in
            let state = stateByID[machineID]
            return DeployIntentMachine(
                id: machineID,
                name: machineID == localID ? "This Mac" : state.map {
                    PublishedStringSanitizer.name($0.name, fallback: "Mac")
                } ?? machineID,
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
