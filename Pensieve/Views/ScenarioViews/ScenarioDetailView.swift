import SwiftData
import SwiftUI

struct ScenarioDetailView: View {
    let scenarioID: UUID
    let onReveal: (Skill) -> Void
    @Environment(\.modelContext) private var context
    @Query private var scenarios: [Scenario]
    @Query(sort: \Skill.name) private var skills: [Skill]
    @State private var model: ScenarioDetailModel
    @State private var showRename = false
    @AppStorage("activeScenarioID") private var activeScenarioID = ""

    init(scenarioID: UUID, platformVM: PlatformViewModel,
         notifier: @escaping SyncStateNotifying, onReveal: @escaping (Skill) -> Void) {
        self.scenarioID = scenarioID
        self.onReveal = onReveal
        _scenarios = Query(filter: #Predicate<Scenario> { $0.id == scenarioID })
        _model = State(initialValue: ScenarioDetailModel(
            store: ScenarioStore(manifestService: ManifestService(), notifier: notifier),
            reconciler: ScenarioReconciler(platformVM: platformVM)
        ))
    }

    var body: some View {
        if let scenario = scenarios.first {
            surface(for: scenario)
        } else {
            ContentUnavailableView("Scenario Not Found", systemImage: "square.grid.2x2")
        }
    }

    @ViewBuilder
    private func surface(for scenario: Scenario) -> some View {
        Form {
            headerSection(for: scenario)
            relatedSkillsSection(for: scenario)

            if let result = model.lastResult {
                Section("Last Action") { resultSummary(result) }
            }

            agentSection(for: scenario)
            skillSection(for: scenario)
        }
        .formStyle(.grouped)
        .navigationTitle(scenario.name)
        .toolbar {
            ToolbarItem {
                Button {
                    if isActive(scenario) {
                        model.deactivate(context: context)
                    } else {
                        model.activate(scenario, context: context)
                    }
                } label: {
                    Label(isActive(scenario) ? "Deactivate" : "Activate",
                          systemImage: isActive(scenario) ? "pause.circle" : "checkmark.circle")
                }
            }

            ToolbarItem {
                Button {
                    showRename = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
        }
        .sheet(isPresented: $showRename) {
            EntityNameSheet(
                title: "Rename Scenario",
                fieldLabel: "Scenario Name",
                actionTitle: "Rename",
                initialName: scenario.name
            ) { name in
                model.rename(scenario, to: name, context: context)
            }
        }
    }

    @ViewBuilder
    private func relatedSkillsSection(for scenario: Scenario) -> some View {
        let relatedSkills = RelatedSkills.forScenario(scenario, in: skills).relatedSkillsOrdered()
        Section("Skills") {
            if relatedSkills.isEmpty {
                Text("No member skills")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(relatedSkills) { skill in
                    Button(action: { onReveal(skill) }, label: {
                        Label(skill.name, systemImage: "doc.text")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    })
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func headerSection(for scenario: Scenario) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(scenario.name)
                    .font(.title2)
                Text(isActive(scenario) ? "Active" : "Inactive")
                    .foregroundStyle(.secondary)
                Text(
                    "\(scenario.skillSlugs.count) member skills · "
                        + "\(enabledAgentCount(for: scenario)) of \(PlatformTarget.allCases.count) agents enabled"
                )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, Spacing.xs)
        } footer: {
            Text("Deploys the selected skills to the enabled agents on this Mac.")
        }
    }

    private func agentSection(for scenario: Scenario) -> some View {
        Section("Agents") {
            ForEach(PlatformTarget.allCases) { platform in
                agentRow(platform, scenario: scenario)
            }
        }
    }

    @ViewBuilder
    private func skillSection(for scenario: Scenario) -> some View {
        Section("Member Skills") {
            if skills.isEmpty {
                Text("Create or import skills first.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(skills) { skill in
                    skillRow(skill, scenario: scenario)
                }
            }
        }
    }

    private func agentRow(_ platform: PlatformTarget, scenario: Scenario) -> some View {
        Toggle(isOn: Binding(
            get: { scenario.agentRawValues.contains(platform.rawValue) },
            set: { model.setAgent(platform, inScenario: scenario, enabled: $0, context: context) }
        )) {
            Label(platform.displayName, systemImage: platform.iconName)
        }
    }

    private func skillRow(_ skill: Skill, scenario: Scenario) -> some View {
        Toggle(isOn: Binding(
            get: { scenario.skillSlugs.contains(skill.directoryName) },
            set: { model.setSkill(skill, inScenario: scenario, assigned: $0, context: context) }
        )) {
            Label(skill.name, systemImage: "doc.text")
        }
    }

    @ViewBuilder
    private func resultSummary(_ result: BatchResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label("\(result.successes.count) \(model.lastActionVerb)", systemImage: "checkmark.circle")
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
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func isActive(_ scenario: Scenario) -> Bool {
        activeScenarioID == scenario.id.uuidString
    }

    private func enabledAgentCount(for scenario: Scenario) -> Int {
        scenario.agentRawValues.compactMap(PlatformTarget.init(rawValue:)).count
    }
}
