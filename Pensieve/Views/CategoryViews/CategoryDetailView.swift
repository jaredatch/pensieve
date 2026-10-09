import SwiftUI
import SwiftData

/// The category management surface: one place to manage a category's member PROJECTS and its assigned
/// SKILLS (the standing rule). Each toggle reconciles and surfaces a resilient §5 result. (PLAN-06 / 06.5)
struct CategoryDetailView: View {
    let categoryID: UUID
    let onReveal: (Skill) -> Void
    @Environment(\.modelContext) private var context
    @Query private var categories: [Category]
    @Query(sort: \Project.name) private var projects: [Project]
    @Query(sort: \Skill.name) private var skills: [Skill]
    @State private var model: CategoryDetailModel
    @State private var showRename = false

    init(categoryID: UUID, platformVM: PlatformViewModel,
         manifestRoot: String, notifier: @escaping SyncStateNotifying, onReveal: @escaping (Skill) -> Void) {
        self.categoryID = categoryID
        self.onReveal = onReveal
        _categories = Query(filter: #Predicate<Category> { $0.id == categoryID })
        _model = State(initialValue: CategoryDetailModel(
            store: CategoryStore(manifestService: ManifestService(), manifestRoot: manifestRoot, notifier: notifier),
            reconciler: CategoryReconciler(platformVM: platformVM)
        ))
    }

    var body: some View {
        if let category = categories.first {
            surface(for: category)
        } else {
            ContentUnavailableView("Category Not Found", systemImage: "square.stack")
        }
    }

    @ViewBuilder
    private func surface(for category: Category) -> some View {
        let agents = PlatformTarget.allCases.filter(\.supportsProjectScope).map(\.displayName).joined(separator: ", ")

        Form {
            headerSection(for: category, agents: agents)
            relatedSkillsSection(for: category)

            if let result = model.lastResult {
                Section("Last Action") { resultSummary(result) }
            }

            Section("Projects") {
                if projects.isEmpty {
                    Text("Add a project in the Projects list first.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(projects) { project in
                        projectRow(project, category: category)
                    }
                }
            }

            Section("Assigned Skills") {
                if skills.isEmpty {
                    Text("Create or import skills first.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(skills) { skill in
                        skillRow(skill, category: category)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(category.name)
        .toolbar {
            ToolbarItem {
                Button {
                    showRename = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
        }
        .sheet(isPresented: $showRename) {
            renameSheet(for: category)
        }
    }

    @ViewBuilder
    private func relatedSkillsSection(for category: Category) -> some View {
        let relatedSkills = RelatedSkills.forCategory(category, in: skills).relatedSkillsOrdered()
        Section("Skills") {
            if relatedSkills.isEmpty {
                Text("No assigned skills")
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

    private func headerSection(for category: Category, agents: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(category.name)
                    .font(.title2)
                Text("\(category.projectKeys.count) projects · \(category.skillSlugs.count) skills")
                    .foregroundStyle(.secondary)
                Text("Deploys to your installed project-capable agents (\(agents)).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, Spacing.xs)
        }
    }

    private func renameSheet(for category: Category) -> some View {
        EntityNameSheet(
            title: "Rename Category",
            fieldLabel: "Category Name",
            actionTitle: "Rename",
            initialName: category.name
        ) { name in
            model.rename(category, to: name, context: context)
        }
    }

    @ViewBuilder
    private func projectRow(_ project: Project, category: Category) -> some View {
        if let key = project.identityKey {
            Toggle(isOn: Binding(
                get: { category.projectKeys.contains(key) },
                set: { model.setProject(project, inCategory: category, member: $0, context: context) }
            )) {
                Label(project.name, systemImage: "folder")
            }
        } else {
            // Pending identity — cannot be a durable member (§A). Shown disabled with a calm hint.
            Label {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(project.name)
                    Text("Resolve this project's identity to add it to a category.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "folder")
            }
            .foregroundStyle(.secondary)
        }
    }

    private func skillRow(_ skill: Skill, category: Category) -> some View {
        Toggle(isOn: Binding(
            get: { category.skillSlugs.contains(skill.directoryName) },
            set: { model.setSkill(skill, inCategory: category, assigned: $0, context: context) }
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
}
