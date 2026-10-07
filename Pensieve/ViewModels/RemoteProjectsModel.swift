import Foundation

/// One window's shared remote-project snapshot. Only changed inputs rebuild its machine models.
struct RemoteProjectsModel {
    struct Inputs: Equatable {
        let machineStates: [MachineState]
        let localProjectIdentityKeys: [String]
        let localMachineID: String?
    }

    private var inputs: Inputs?
    private(set) var projects: [RemoteProjectModel] = []

    /// Reports a replacement so the window can prune selection against the new snapshot.
    mutating func refresh(_ inputs: Inputs, now: @escaping () -> Date) -> Bool {
        let keys = Set(inputs.localProjectIdentityKeys)
        let normalized = Inputs(
            machineStates: inputs.machineStates.sorted { $0.machineID < $1.machineID },
            localProjectIdentityKeys: keys.sorted(), localMachineID: inputs.localMachineID
        )
        guard self.inputs != normalized else { return false }
        self.inputs = normalized
        projects = RemoteProjectModel.onlyOnOtherMacs(
            states: normalized.machineStates, localProjectIdentityKeys: keys,
            localMachineID: normalized.localMachineID, now: now
        )
        return true
    }
}
