import SwiftData
import SwiftUI

struct CategoryListView: View {
    @Binding var entitySelection: EntitySelection?
    @Binding var searchText: String
    let platformVM: PlatformViewModel
    @Environment(\.modelContext) private var context
    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: \Project.name) private var projects: [Project]
    @Query(sort: \Skill.name) private var skills: [Skill]
    @State private var categoryToRename: Category?
    @State private var removalError: String?
    @AppStorage(ListPreferenceKeys.showsLine2(.categories)) private var showsLine2 = true
    @AppStorage(ListPreferenceKeys.showsLine3(.categories)) private var showsLine3 = true
    private let categoryStore: CategoryStoreProtocol
    let onAdd: () -> Void
    let addsFenced: Bool

    init(entitySelection: Binding<EntitySelection?>, searchText: Binding<String>,
         platformVM: PlatformViewModel, manifestRoot: String, notifier: @escaping SyncStateNotifying, onAdd: @escaping () -> Void,
         addsFenced: Bool) {
        _entitySelection = entitySelection
        _searchText = searchText
        self.platformVM = platformVM
        self.categoryStore = CategoryStore(manifestService: ManifestService(), manifestRoot: manifestRoot, notifier: notifier)
        self.onAdd = onAdd
        self.addsFenced = addsFenced
    }

    private var filteredCategories: [Category] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return categories }
        return categories.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        List(selection: $entitySelection) {
            ForEach(filteredCategories) { category in
                ListRowView(model: ListRows.category(category, projects: projects, skills: skills),
                            showsLine2: showsLine2, showsLine3: showsLine3)
                    .tag(EntitySelection.category(category.id))
                    .contextMenu {
                        Button("Rename") {
                            categoryToRename = category
                        }

                        Button("Remove", role: .destructive) {
                            let result = categoryStore.delete(
                                category,
                                reconciler: CategoryReconciler(platformVM: platformVM),
                                context: context
                            )
                            if result.hasFailures {
                                var messages = result.readFailures.map(\.message)
                                if !result.failures.isEmpty {
                                    messages.insert(
                                        "Couldn't fully remove “\(category.name)” — "
                                            + "\(result.failures.count) project change(s) failed.",
                                        at: 0
                                    )
                                }
                                removalError = messages.joined(separator: "\n\n")
                            }
                        }
                    }
            }
        }
        .navigationTitle("Categories")
        .navigationSubtitle(ListSubtitle.text(total: categories.count, shown: filteredCategories.count,
                                              singular: "category", plural: "categories"))
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        .searchable(text: $searchText, placement: .automatic, prompt: "Search")
        .overlay {
            if filteredCategories.isEmpty {
                if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    EmptyStateView("No Categories",
                                   description: "Add a category to assign skills across projects.") {
                        Button("Add Category") { onAdd() }
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
                ListViewOptionsMenu(section: .categories, showsLine2: $showsLine2, showsLine3: $showsLine3)
            }
        }
        .sheet(item: $categoryToRename) { category in
            EntityNameSheet(
                title: "Rename Category",
                fieldLabel: "Category Name",
                actionTitle: "Rename",
                initialName: category.name
            ) { name in
                categoryStore.rename(category, to: name, context: context)
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
