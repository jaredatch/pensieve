import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class SkillDeploymentsTabPresentation {
    var expandedProjects: Set<DeploymentProjectID> = []

    func reset() {
        expandedProjects.removeAll()
    }
}

/// The Deployments tab's full-width Settings-style groups, drawn from primitives so the boxes share
/// the detail column's 16 pt edge instead of acquiring a stock container's width and insets. Switches
/// drive the existing deploy/remove paths; the snapshot reloads on `refreshCounter`, and rows stay
/// disabled until it has. The Add Project footer opens the app's Add Project sheet.
struct SkillDeploymentsTab: View {
    let homeDirectory: String
    let skill: Skill
    let snapshot: DetailContentSnapshot
    let statusIsCurrent: Bool
    let projects: [Project]
    @Bindable var platformVM: PlatformViewModel
    let addsFenced: Bool
    let onAddProject: () -> Void
    @Environment(\.modelContext) var context
    @Query var intentRows: [MachineDeployIntent]
    @State var intentModel: DeployIntentModel
    @State private var ownedPresentation = SkillDeploymentsTabPresentation()
    private let hostedPresentation: SkillDeploymentsTabPresentation?
    let machineStates: [MachineState]
    let localMachineID: String?

    var presentation: SkillDeploymentsTabPresentation { hostedPresentation ?? ownedPresentation }

    /// The project row's name occupies x 56–228, placing the path at x 240.
    static let nameColumn: CGFloat = 172

    init(
        skill: Skill,
        snapshot: DetailContentSnapshot,
        statusIsCurrent: Bool,
        projects: [Project],
        platformVM: PlatformViewModel,
        addsFenced: Bool,
        intentDependencies: DeployIntentDependencies,
        machineStates: [MachineState],
        localMachineID: String?,
        hostedIntentModel: DeployIntentModel? = nil,
        hostedPresentation: SkillDeploymentsTabPresentation? = nil,
        homeDirectory: String,
        onAddProject: @escaping () -> Void
    ) {
        self.homeDirectory = homeDirectory
        self.skill = skill
        self.snapshot = snapshot
        self.statusIsCurrent = statusIsCurrent
        self.projects = projects
        self.platformVM = platformVM
        self.addsFenced = addsFenced
        self.machineStates = machineStates
        self.localMachineID = localMachineID
        self.hostedPresentation = hostedPresentation
        self.onAddProject = onAddProject
        let skillSlug = skill.directoryName
        _intentRows = Query(filter: #Predicate<MachineDeployIntent> { row in
            row.skillSlug == skillSlug
        })
        _intentModel = State(initialValue: hostedIntentModel ?? DeployIntentModel(
            platformVM: platformVM,
            dependencies: intentDependencies
        ))
    }

    var body: some View {
        let macSection = DeploymentsPresentation.macSection(
            installed: platformVM.deployablePlatforms(forProject: false),
            status: snapshot.macStatus,
            statusIsCurrent: statusIsCurrent
        )
        let facts = DeploymentsPresentation.intentFacts(intentRows, skillSlug: skill.directoryName)
        let remote = DeploymentsPresentation.remoteContent(
            skillSlug: skill.directoryName,
            machineStates: machineStates,
            localMachineID: localMachineID,
            intents: facts,
            heldRetractions: intentModel.dependencies.remoteRetractions.held
        )
        let localProjectRows = DeploymentsPresentation.projectRows(
            projects: projects,
            projectPlatforms: platformVM.deployablePlatforms(forProject: true),
            macStatus: snapshot.macStatus,
            projectStatus: snapshot.projectStatus,
            homeDirectory: homeDirectory,
            statusIsCurrent: statusIsCurrent,
            prefixesThisMac: !remote.machines.isEmpty
        )
        let projectRows = DeploymentsPresentation.sortedProjectRows(localProjectRows + remote.projects)

        VStack(alignment: .leading, spacing: 0) {
            thisMacSection(macSection)
            ForEach(remote.machines) { machine in
                sectionSpacing
                remoteMachineSection(machine)
            }
            sectionSpacing
            projectsSection(projectRows)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, DesignTokens.stripHairlineToContentTop)
        .padding(.bottom, Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: skill.id) { _, _ in resetPresentation() }
        .alert("Couldn't update deployment", isPresented: Binding(
            get: { intentModel.error != nil },
            set: { if !$0 { intentModel.error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(intentModel.error ?? "")
        }
    }

    private func resetPresentation() {
        presentation.reset()
        intentModel.error = nil
    }

}
