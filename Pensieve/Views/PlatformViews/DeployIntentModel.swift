import Observation
import SwiftData

/// Window presentation delegates deployment decisions to the runtime's shared mutation service.
@MainActor
@Observable
final class DeployIntentModel {
    let service: DeployMutationServicing
    var platformVM: PlatformViewModel { service.platformVM }
    var dependencies: DeployIntentDependencies { service.dependencies }
    var machines: [DeployIntentMachine] { service.machines }
    var availablePlatforms: [PlatformTarget] { service.availablePlatforms }
    var error: String?

    init(service: DeployMutationServicing) { self.service = service }

    convenience init(platformVM: PlatformViewModel, dependencies: DeployIntentDependencies) {
        self.init(service: DeployMutationService(platformVM: platformVM, dependencies: dependencies))
    }

    func reload(context: ModelContext) {
        do {
            try service.reload(context: context)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func selectedMachineIDs(skills: [Skill], platforms: Set<PlatformTarget>, context: ModelContext) throws -> Set<String> {
        do { return try service.selectedMachineIDs(skills: skills, platforms: platforms, context: context) } catch {
            self.error = "Deployment selection could not be read: \(error.localizedDescription)"
            throw error
        }
    }

    func setRemote(_ selected: Bool, machineID: String, projectKey: String?, skill: Skill,
                   platform: PlatformTarget, context: ModelContext) throws {
        try reportErrors {
            try service.setRemote(selected, machineID: machineID, projectKey: projectKey,
                                  skill: skill, platform: platform, context: context)
        }
    }

    func set(_ selected: Bool, skill: Skill, platform: PlatformTarget, target: DeployTarget,
             context: ModelContext) throws -> BatchResult {
        let result = try reportErrors {
            try service.set(selected, skill: skill, platform: platform, target: target, context: context)
        }
        presentFailures(result)
        return result
    }

    func setProjectSelection(_ selected: Bool, skills: [Skill], platforms: Set<PlatformTarget>,
                             project: Project, context: ModelContext) throws -> DeployIntentApplyOutcome {
        let outcome = try reportErrors {
            try service.setProjectSelection(selected, skills: skills, platforms: platforms, project: project, context: context)
        }
        if case let .localDeploy(result) = outcome { presentFailures(result) }
        return outcome
    }

    @discardableResult
    func setSelected(_ selected: Bool, machineID: String, skill: Skill, platform: PlatformTarget,
                     context: ModelContext) throws -> BatchResult? {
        let result = try reportErrors {
            try service.setSelected(selected, machineID: machineID, skill: skill, platform: platform, context: context)
        }
        // Refreshing the picker must not turn an already applied change into a failure.
        do {
            try service.reload(context: context)
        } catch {
            self.error = "The change applied, but the list of Macs and agents couldn't refresh: \(error.localizedDescription)"
        }
        return result
    }

    func apply(skills: [Skill], platforms: Set<PlatformTarget>, selectedMachineIDs: Set<String>,
               context: ModelContext) throws -> DeployIntentApplyOutcome {
        try reportErrors {
            try service.apply(skills: skills, platforms: platforms, selectedMachineIDs: selectedMachineIDs, context: context)
        }
    }

    func retract(skills: [Skill], platforms: Set<PlatformTarget>, machineIDs: Set<String>,
                 context: ModelContext) throws -> DeployIntentApplyOutcome {
        try reportErrors {
            try service.retract(skills: skills, platforms: platforms, machineIDs: machineIDs, context: context)
        }
    }

    private func reportErrors<T>(_ operation: () throws -> T) throws -> T {
        do {
            let value = try operation()
            error = nil
            return value
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    private func presentFailures(_ result: BatchResult) {
        let messages = result.readFailures.map(\.message) + result.failures.compactMap(\.error)
        error = messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
}
