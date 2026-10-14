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
    var error: String? {
        get { service.error }
        set { service.error = newValue }
    }

    init(service: DeployMutationServicing) { self.service = service }

    convenience init(platformVM: PlatformViewModel, dependencies: DeployIntentDependencies) {
        self.init(service: DeployMutationService(platformVM: platformVM, dependencies: dependencies))
    }

    func reload(context: ModelContext) { service.reload(context: context) }

    func selectedMachineIDs(skills: [Skill], platforms: Set<PlatformTarget>, context: ModelContext) throws -> Set<String> {
        try service.selectedMachineIDs(skills: skills, platforms: platforms, context: context)
    }

    func setRemote(_ selected: Bool, machineID: String, projectKey: String?, skill: Skill,
                   platform: PlatformTarget, context: ModelContext) throws {
        try service.setRemote(selected, machineID: machineID, projectKey: projectKey,
                              skill: skill, platform: platform, context: context)
    }

    func set(_ selected: Bool, skill: Skill, platform: PlatformTarget, target: DeployTarget,
             context: ModelContext) throws -> BatchResult {
        try service.set(selected, skill: skill, platform: platform, target: target, context: context)
    }

    func setProjectSelection(_ selected: Bool, skills: [Skill], platforms: Set<PlatformTarget>,
                             project: Project, context: ModelContext) throws -> DeployIntentApplyOutcome {
        try service.setProjectSelection(selected, skills: skills, platforms: platforms, project: project, context: context)
    }

    @discardableResult
    func setSelected(_ selected: Bool, machineID: String, skill: Skill, platform: PlatformTarget,
                     context: ModelContext) throws -> BatchResult? {
        try service.setSelected(selected, machineID: machineID, skill: skill, platform: platform, context: context)
    }

    func apply(skills: [Skill], platforms: Set<PlatformTarget>, selectedMachineIDs: Set<String>,
               context: ModelContext) throws -> DeployIntentApplyOutcome {
        try service.apply(skills: skills, platforms: platforms, selectedMachineIDs: selectedMachineIDs, context: context)
    }

    func retract(skills: [Skill], platforms: Set<PlatformTarget>, machineIDs: Set<String>,
                 context: ModelContext) throws -> DeployIntentApplyOutcome {
        try service.retract(skills: skills, platforms: platforms, machineIDs: machineIDs, context: context)
    }
}
