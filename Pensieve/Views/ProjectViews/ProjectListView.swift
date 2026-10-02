import SwiftData
import SwiftUI

struct ProjectListView: View {
    @Binding var entitySelection: EntitySelection?
    @Binding var searchText: String
    let platformVM: PlatformViewModel
    @Environment(\.modelContext) private var context
    @Query(sort: \Project.name) private var projects: [Project]
    @State private var removalError: String?
    @AppStorage(ListPreferenceKeys.showsLine2(.projects)) private var showsLine2 = true
    @AppStorage(ListPreferenceKeys.showsLine3(.projects)) private var showsLine3 = true
    private let categoryStore: CategoryStoreProtocol
    private let notifier: SyncStateNotifying
    let onAdd: () -> Void
    let addsFenced: Bool

    init(entitySelection: Binding<EntitySelection?>, searchText: Binding<String>,
         platformVM: PlatformViewModel, notifier: @escaping SyncStateNotifying, onAdd: @escaping () -> Void,
         addsFenced: Bool) {
        _entitySelection = entitySelection
        _searchText = searchText
        self.platformVM = platformVM
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
        if !result.readFailures.isEmpty {
            return """
            Removal stopped because Pensieve couldn't read its deploy records. \
            “\(projectName)” stays registered so you can retry.
            """
        }
        return """
        Couldn't fully remove “\(projectName)” — \(result.failures.count) skill removal(s) failed. \
        It stays registered so you can retry.
        """
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
                        let result = removeRegisteredProject(
                            project,
                            categoryStore: categoryStore,
                            reconciler: CategoryReconciler(platformVM: platformVM),
                            manifestService: ManifestService(),
                            context: context,
                            notifier: notifier
                        )
                        if result.hasFailures {
                            removalError = Self.removalFailureMessage(projectName: project.name, result: result)
                        }
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
                    ContentUnavailableView {
                        Label("No Projects", systemImage: "folder")
                    } description: {
                        Text("Add a project to organize and deploy skills by workspace.")
                    } actions: {
                        Button("Add Project") { onAdd() }
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
                ListViewOptionsMenu(section: .projects, showsLine2: $showsLine2, showsLine3: $showsLine3)
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
