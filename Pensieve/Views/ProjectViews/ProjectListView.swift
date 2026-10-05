import SwiftData
import SwiftUI

struct ProjectListView: View {
    @Binding var entitySelection: EntitySelection?
    @Binding var searchText: String
    let platformVM: PlatformViewModel
    let localMachineID: String?
    @Environment(\.modelContext) private var context
    @Query(sort: \Project.name) private var projects: [Project]
    @State private var removal = ProjectRemovalModel()
    @State private var confirmingRemoval = false
    @AppStorage(ListPreferenceKeys.showsLine2(.projects)) private var showsLine2 = true
    @AppStorage(ListPreferenceKeys.showsLine3(.projects)) private var showsLine3 = true
    private let categoryStore: CategoryStoreProtocol
    private let notifier: SyncStateNotifying
    let onAdd: () -> Void
    let addsFenced: Bool

    init(entitySelection: Binding<EntitySelection?>, searchText: Binding<String>,
         platformVM: PlatformViewModel, localMachineID: String?, notifier: @escaping SyncStateNotifying,
         onAdd: @escaping () -> Void,
         addsFenced: Bool) {
        _entitySelection = entitySelection
        _searchText = searchText
        self.platformVM = platformVM
        self.localMachineID = localMachineID
        self.notifier = notifier
        self.categoryStore = CategoryStore(manifestService: ManifestService(), notifier: notifier)
        self.onAdd = onAdd
        self.addsFenced = addsFenced
    }

    private var filteredProjects: [Project] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return projects }
        return projects.filter { $0.name.lowercased().contains(query) }
    }

    static func removalFailureMessage(projectName: String, result: BatchResult) -> String {
        let details = (result.failures.compactMap(\.error) + result.readFailures.map(\.message)
                       + result.operationFailures).joined(separator: " ")
        if !result.readFailures.isEmpty {
            return "Removal stopped because Pensieve couldn't read its deploy records. "
                + "“\(projectName)” stays registered so you can retry. " + details
        }
        return "Couldn't remove “\(projectName)”: " + details + " It stays registered so you can retry."
    }

    @discardableResult
    static func removeProject(_ project: Project, removalError: inout String?, perform: () -> BatchResult) -> BatchResult {
        let name = project.name
        let result = perform()
        if result.hasFailures {
            removalError = removalFailureMessage(projectName: name, result: result)
        }
        return result
    }

    var body: some View {
        List(selection: $entitySelection) {
            ForEach(filteredProjects) { project in
                ListRowView(model: ListRows.project(project, deployIndex: platformVM.deployIndex,
                                                     homeDirectory: Constants.homeDirectory),
                            showsLine2: showsLine2, showsLine3: showsLine3)
                .tag(EntitySelection.project(project.id))
                .contextMenu {
                    Button("Remove", role: .destructive) {
                        removal.request(project, platformVM: platformVM, context: context)
                        confirmingRemoval = removal.project != nil
                    }
                }
            }
        }
        .navigationTitle("Projects")
        .navigationSubtitle(ListSubtitle.text(total: projects.count, shown: filteredProjects.count,
                                              singular: "project", plural: "projects"))
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        .searchable(text: $searchText, placement: .automatic, prompt: "Search")
        .overlay {
            if filteredProjects.isEmpty {
                if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    EmptyStateView("No Projects",
                                   description: "Add a project to organize and deploy skills by workspace.") {
                        Button("Add Project") { onAdd() }
                            .buttonStyle(.borderedProminent)
                            .disabled(addsFenced)
                    }
                } else {
                    EmptyStateView.search(text: searchText)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ListViewOptionsMenu(section: .projects, showsLine2: $showsLine2, showsLine3: $showsLine3)
            }
        }
        .confirmationDialog(removal.preview?.title ?? "Remove project?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible) {
                Button("Remove Project", role: .destructive) {
                    removal.confirm { project in
                        removeRegisteredProject(project, categoryStore: categoryStore,
                            reconciler: CategoryReconciler(platformVM: platformVM), manifestService: ManifestService(),
                            platformVM: platformVM, localMachineID: localMachineID, context: context, notifier: notifier)
                    }
                }
                Button("Cancel", role: .cancel) { removal.cancel() }
            } message: {
                Text(removal.preview?.message ?? "")
            }
        .alert(
            "Removal incomplete",
            isPresented: Binding(
                get: { removal.error != nil },
                set: { if !$0 { removal.error = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removal.error ?? "")
        }
    }
}
