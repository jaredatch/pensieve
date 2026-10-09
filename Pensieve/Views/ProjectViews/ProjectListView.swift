import SwiftData
import SwiftUI

struct ProjectListView: View {
    @Environment(AppRuntime.self) private var runtime
    @Binding var entitySelection: EntitySelection?
    @Binding var searchText: String
    let platformVM: PlatformViewModel
    let remoteProjects: [RemoteProjectModel]
    let localMachineID: String?
    @Environment(\.modelContext) private var context
    @Query(sort: \Project.name) private var projects: [Project]
    @State private var removal = ProjectRemovalModel()
    @State private var confirmingRemoval = false
    @AppStorage(ListPreferenceKeys.showsLine2(.projects)) private var showsLine2 = true
    @AppStorage(ListPreferenceKeys.showsLine3(.projects)) private var showsLine3 = true
    private let notifier: SyncStateNotifying
    let onAdd: () -> Void
    let addsFenced: Bool

    init(entitySelection: Binding<EntitySelection?>, searchText: Binding<String>,
         platformVM: PlatformViewModel, remoteProjects: [RemoteProjectModel], localMachineID: String?,
         notifier: @escaping SyncStateNotifying,
         onAdd: @escaping () -> Void,
         addsFenced: Bool) {
        _entitySelection = entitySelection
        _searchText = searchText
        self.platformVM = platformVM
        self.remoteProjects = remoteProjects
        self.localMachineID = localMachineID
        self.notifier = notifier
        self.onAdd = onAdd
        self.addsFenced = addsFenced
    }

    private var model: ProjectListModel {
        ProjectListModel(
            projects: projects,
            remoteProjects: remoteProjects,
            deployIndex: platformVM.deployIndex, homeDirectory: runtime.paths.homeDirectory, searchText: searchText
        )
    }

    var body: some View {
        let model = model
        List(selection: $entitySelection) {
            ForEach(model.rows) { row in
                ListRowView(model: row.presentation,
                            showsLine2: showsLine2, showsLine3: showsLine3)
                .tag(row.selection)
                .contextMenu {
                    if let project = row.localProject {
                        Button("Remove", role: .destructive) {
                            removal.request(project, platformVM: platformVM, context: context)
                            confirmingRemoval = removal.project != nil
                        }
                    }
                }
            }
        }
        .navigationTitle("Projects")
        .navigationSubtitle(model.subtitle)
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        .searchable(text: $searchText, placement: .automatic, prompt: "Search")
        .overlay {
            if model.rows.isEmpty {
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
                    removal.confirm { project, preview in
                        removeRegisteredProject(project,
                            reconciler: CategoryReconciler(platformVM: platformVM), manifestService: ManifestService(),
                            manifestRoot: runtime.paths.storeRoot,
                            platformVM: platformVM, localMachineID: localMachineID, confirmedPreview: preview,
                            context: context, notifier: notifier)
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
