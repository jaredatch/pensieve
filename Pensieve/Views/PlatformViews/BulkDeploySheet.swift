import SwiftUI
import SwiftData

/// Bulk-deploy (or remove) the multi-selected skills across a chosen set of installed agents.
/// Resilient: surfaces the per-pair `BatchResult` — successes quietly, failures called out.
struct BulkDeploySheet: View {
    enum BulkDeployAction { case deploy, remove }

    let skills: [Skill]
    @Bindable var platformVM: PlatformViewModel

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.name) private var projects: [Project]

    @State private var selectedTarget: DeployTarget = .userWide
    @State private var selectedPlatforms: Set<PlatformTarget> = []
    @State private var result: BatchResult?
    /// Past-tense verb for the result summary — set to "deployed"/"removed" by the action taken,
    /// so the summary reads correctly whether the user tapped Deploy or Remove.
    @State private var actionVerb = "deployed"
    @State private var selectedMachines: Set<String> = []
    @State private var machineSelectionWasEdited = false
    @State private var machineSelectionIsKnown = false
    @State private var intentSaved = false
    @State private var intentModel: DeployIntentModel

    private var forProject: Bool { selectedTarget.project != nil }
    private var installed: [PlatformTarget] {
        forProject ? platformVM.deployablePlatforms(forProject: true) : intentModel.availablePlatforms
    }

    init(
        skills: [Skill],
        platformVM: PlatformViewModel,
        intentDependencies: DeployIntentDependencies
    ) {
        self.skills = skills
        self.platformVM = platformVM
        _intentModel = State(initialValue: DeployIntentModel(
            platformVM: platformVM,
            dependencies: intentDependencies
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("\(skills.count) \(skills.count == 1 ? "Skill" : "Skills")")
                    .font(.title2)
                Text(skills.map(\.name).sorted().joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let result {
                resultSummary(result)
            } else if intentSaved {
                Label("Deployment intent updated", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                chooser
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(Spacing.xl)
        .frame(width: 440, height: 480)
        .onAppear {
            intentModel.reload(context: context)
            refreshMachineSelection()
        }
        .onChange(of: selectedTarget) {
            selectedPlatforms.formIntersection(Set(installed))
        }
        .onChange(of: selectedPlatforms) {
            guard !machineSelectionWasEdited else { return }
            refreshMachineSelection()
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            targetPicker

            if !forProject {
                machinePicker
            }
            if let error = intentModel.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("Target agents")
                .font(.headline)
            if installed.isEmpty {
                Text("No supported agents detected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(installed) { platform in
                    Toggle(isOn: binding(for: platform)) {
                        Label(platform.displayName, systemImage: platform.iconName)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    @ViewBuilder
    private func resultSummary(_ result: BatchResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label("\(result.successes.count) \(actionVerb)", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
            if !result.failures.isEmpty {
                Text("\(result.failures.count) failed")
                    .font(.headline)
                    .foregroundStyle(.red)
                ForEach(result.failures) { failure in
                    Text("• \(failure.skillName) → \(failure.platform.displayName): \(failure.error ?? "failed")")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            ForEach(result.readFailures) { failure in
                Text(failure.message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            if result == nil, !intentSaved {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Remove") {
                    run(.remove)
                }
                .environment(
                    \.isEnabled,
                    !selectedPlatforms.isEmpty
                        && (forProject || (machineSelectionIsKnown && !selectedMachines.isEmpty))
                )
                Button("Deploy") {
                    run(.deploy)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .environment(
                    \.isEnabled,
                    !selectedPlatforms.isEmpty
                        && (forProject || (machineSelectionIsKnown
                            && (!selectedMachines.isEmpty || machineSelectionWasEdited)))
                )
            } else {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var machinePicker: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Target machines")
                .font(.headline)
            ForEach(intentModel.machines) { machine in
                Toggle(isOn: Binding(
                    get: { selectedMachines.contains(machine.id) },
                    set: { selected in
                        machineSelectionWasEdited = true
                        if selected { selectedMachines.insert(machine.id) } else {
                            selectedMachines.remove(machine.id)
                        }
                    }
                )) {
                    HStack(spacing: Spacing.sm) {
                        Text(machine.name)
                        if machine.isUnseen {
                            Text("unseen")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!machineSelectionIsKnown)
            }
        }
    }

    private func binding(for platform: PlatformTarget) -> Binding<Bool> {
        Binding(
            get: { selectedPlatforms.contains(platform) },
            set: { isOn in
                if isOn { selectedPlatforms.insert(platform) } else { selectedPlatforms.remove(platform) }
            }
        )
    }

    private func refreshMachineSelection() {
        do {
            selectedMachines = try intentModel.selectedMachineIDs(
                skills: skills, platforms: selectedPlatforms, context: context
            )
            machineSelectionIsKnown = true
            if selectedMachines.isEmpty, let local = intentModel.machines.first(where: \.isLocal) {
                selectedMachines.insert(local.id)
            }
        } catch {
            selectedMachines = []
            machineSelectionIsKnown = false
        }
    }

    private func run(_ action: BulkDeployAction) {
        guard forProject || machineSelectionIsKnown else { return }
        actionVerb = action == .deploy ? "deployed" : "removed"
        do {
            switch try Self.perform(
                action, forProject: forProject, platformVM: platformVM, intentModel: intentModel,
                skills: skills, platforms: selectedPlatforms, target: selectedTarget,
                machineIDs: selectedMachines, context: context
            ) {
            case .intentOnly:
                intentSaved = true
            case let .localDeploy(batchResult):
                result = batchResult
            }
        } catch {
            // `DeployIntentModel` retains the actionable error for the picker surface.
        }
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text("Deploy target")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Deploy target", selection: $selectedTarget) {
                Text("This Mac").tag(DeployTarget.userWide)
                ForEach(projects) { project in
                    Text(project.name).tag(DeployTarget.project(project))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
        }
    }
}

extension BulkDeploySheet {
    @MainActor
    // swiftlint:disable:next function_parameter_count
    static func perform(
        _ action: BulkDeployAction,
        forProject: Bool,
        platformVM: PlatformViewModel,
        intentModel: DeployIntentModel,
        skills: [Skill],
        platforms: Set<PlatformTarget>,
        target: DeployTarget,
        machineIDs: Set<String>,
        context: ModelContext
    ) throws -> DeployIntentApplyOutcome {
        if forProject, let project = target.project {
            return try intentModel.setProjectSelection(
                action == .deploy,
                skills: skills,
                platforms: platforms,
                project: project,
                context: context
            )
        }
        return switch action {
        case .deploy:
            try intentModel.apply(
                skills: skills, platforms: platforms, selectedMachineIDs: machineIDs, context: context
            )
        case .remove:
            try intentModel.retract(
                skills: skills, platforms: platforms, machineIDs: machineIDs, context: context
            )
        }
    }
}
