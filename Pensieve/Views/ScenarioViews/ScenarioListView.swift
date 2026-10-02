import SwiftData
import SwiftUI

struct ScenarioListView: View {
    @Binding var entitySelection: EntitySelection?
    @Binding var searchText: String
    let platformVM: PlatformViewModel
    @Environment(\.modelContext) private var context
    @Query(sort: \Scenario.name) private var scenarios: [Scenario]
    @Query(sort: \Skill.name) private var skills: [Skill]
    @State private var scenarioToRename: Scenario?
    @State private var removalError: String?
    @AppStorage("activeScenarioID") private var activeScenarioID = ""
    @AppStorage(ListPreferenceKeys.showsLine2(.scenarios)) private var showsLine2 = true
    @AppStorage(ListPreferenceKeys.showsLine3(.scenarios)) private var showsLine3 = true
    private let scenarioStore: ScenarioStoreProtocol
    let onAdd: () -> Void
    let addsFenced: Bool

    init(entitySelection: Binding<EntitySelection?>, searchText: Binding<String>,
         platformVM: PlatformViewModel, notifier: @escaping SyncStateNotifying, onAdd: @escaping () -> Void,
         addsFenced: Bool) {
        _entitySelection = entitySelection
        _searchText = searchText
        self.platformVM = platformVM
        self.scenarioStore = ScenarioStore(manifestService: ManifestService(), notifier: notifier)
        self.onAdd = onAdd
        self.addsFenced = addsFenced
    }

    private var filteredScenarios: [Scenario] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return scenarios }
        return scenarios.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        List(selection: $entitySelection) {
            ForEach(filteredScenarios) { scenario in
                ListRowView(model: ListRows.scenario(scenario, skills: skills,
                                                      isActive: activeScenarioID == scenario.id.uuidString),
                            showsLine2: showsLine2, showsLine3: showsLine3)
                .tag(EntitySelection.scenario(scenario.id))
                .contextMenu {
                    Button("Rename") {
                        scenarioToRename = scenario
                    }

                    Button("Remove", role: .destructive) {
                        let result = scenarioStore.delete(
                            scenario,
                            reconciler: ScenarioReconciler(platformVM: platformVM),
                            context: context
                        )
                        if result.hasFailures {
                            var messages = result.readFailures.map(\.message)
                            if !result.failures.isEmpty {
                                messages.insert(
                                    "Couldn't fully remove “\(scenario.name)” — "
                                        + "\(result.failures.count) scenario deploy(s) failed.",
                                    at: 0
                                )
                            }
                            removalError = messages.joined(separator: "\n\n")
                        }
                    }
                }
            }
        }
        .navigationTitle("Scenarios")
        .navigationSubtitle(ListSubtitle.text(total: scenarios.count, shown: filteredScenarios.count,
                                              singular: "scenario", plural: "scenarios"))
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        .searchable(text: $searchText, placement: .automatic, prompt: "Search")
        .overlay {
            if filteredScenarios.isEmpty {
                if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView {
                        Label("No Scenarios", systemImage: "square.grid.2x2")
                    } description: {
                        Text("Add a scenario to switch groups of skills and agents together.")
                    } actions: {
                        Button("Add Scenario") { onAdd() }
                            .buttonStyle(.borderedProminent)
                            .disabled(addsFenced)
                    }
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ListViewOptionsMenu(section: .scenarios, showsLine2: $showsLine2, showsLine3: $showsLine3)
            }
        }
        .sheet(item: $scenarioToRename) { scenario in
            EntityNameSheet(
                title: "Rename Scenario",
                fieldLabel: "Scenario Name",
                actionTitle: "Rename",
                initialName: scenario.name
            ) { name in
                scenarioStore.rename(scenario, to: name, context: context)
            }
        }
        .alert(
            "Removal incomplete",
            isPresented: Binding(
                get: { removalError != nil },
                set: { if !$0 { removalError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removalError ?? "")
        }
    }
}
