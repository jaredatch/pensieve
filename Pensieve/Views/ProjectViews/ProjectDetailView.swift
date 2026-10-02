import SwiftData
import SwiftUI

struct ProjectDetailView: View {
    let projectID: UUID
    let platformVM: PlatformViewModel
    let library: SkillLibraryViewModel
    let onReveal: (Skill) -> Void
    @Query(sort: \Project.name) private var projects: [Project]
    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: [SortDescriptor(\Skill.name), SortDescriptor(\Skill.directoryName)])
    private var skills: [Skill]

    /// Every input ProjectSkillsSnapshot.load reads FROM THE MODEL, stamped by VALUE, in STRUCTURED form — a
    /// delimiter-joined string can collide (a slug containing the delimiter), and a count cannot see a
    /// substitution at all. The Cursor fields are here because `isDeployed` is not purely path-based:
    /// for the compiled platforms it routes to `CursorCompiler.isUpToDate`, which regenerates the .mdc
    /// from the skill's body, `name`, `skillDescription`, and `cursorConfig` and compares it to what is
    /// on disk — so editing a description or a Cursor config flips the answer with every id and slug
    /// unchanged. BOTH library revisions are here because they cover different halves and neither
    /// covers the other: `reloadToken` is bumped only when an EXTERNAL change is accepted
    /// (`SkillLibraryViewModel:78` documents it as exactly that; bumped at :274 and :353), while a save
    /// the app itself makes bumps `appWriteRevision` (:59, :370). `DetailView` observes both (:174).
    private struct SkillStamp: Hashable {
        let id: UUID
        let directoryName: String
        let name: String
        let skillDescription: String
        let updatedAt: Date
        let cursorConfigData: Data?
    }
    private struct CategoryStamp: Hashable {
        let id: UUID
        let projectKeys: [String]
        let skillSlugs: [String]
    }
    private struct ReloadKey: Hashable {
        let projectID: UUID
        let projectPath: String
        let projectIdentityKey: String?
        let refreshCounter: Int
        let reloadToken: Int
        let appWriteRevision: Int
        let skillStamps: [SkillStamp]
        let categoryStamps: [CategoryStamp]
    }
    private var reloadKey: ReloadKey {
        ReloadKey(projectID: projectID,
                  projectPath: project?.path ?? "",
                  projectIdentityKey: project?.identityKey,
                  refreshCounter: platformVM.refreshCounter,
                  reloadToken: library.reloadToken,
                  appWriteRevision: library.appWriteRevision,
                  skillStamps: skills.map {
                      SkillStamp(id: $0.id, directoryName: $0.directoryName, name: $0.name,
                                 skillDescription: $0.skillDescription, updatedAt: $0.updatedAt,
                                 cursorConfigData: $0.cursorConfigData)
                  },
                  categoryStamps: categories.map {
                      CategoryStamp(id: $0.id, projectKeys: $0.projectKeys, skillSlugs: $0.skillSlugs)
                  })
    }

    private struct Loaded: Equatable { let key: ReloadKey; let snapshot: ProjectSkillsSnapshot }
    @State private var loaded: Loaded?
    /// The rows for the key on screen — EMPTY, never stale, for the one frame after any input changes.
    /// PLAN-26's DetailView split this into two keys so body text would not flash; here the whole
    /// surface is a list, so one frame of "no rows" is the right trade and a stale row is not.
    private var snapshot: ProjectSkillsSnapshot {
        if let loaded, loaded.key == reloadKey { return loaded.snapshot }
        return ProjectSkillsSnapshot()
    }

    private var project: Project? {
        projects.first(where: { $0.id == projectID })
    }

    var body: some View {
        if let project {
            projectContent(project)
        } else {
            ContentUnavailableView("Project Not Found", systemImage: "folder")
        }
    }

    private func projectContent(_ project: Project) -> some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(project.name)
                        .font(.title2)
                    Label(
                        ProjectIdentityPresentation.label(for: project),
                        systemImage: ProjectIdentityPresentation.symbol(for: project)
                    )
                    .foregroundStyle(.secondary)
                    Text(project.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .padding(.vertical, Spacing.xs)
            }

            Section {
                LabeledContent("Categories") {
                    categoriesContent(for: project)
                }
            }

            Section {
                if snapshot.rows.isEmpty {
                    Text("No skills reach this project")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.rows) { row in
                        projectSkillRow(row)
                    }
                }
            } header: {
                Text("Skills")
            } footer: {
                Text("\(snapshot.deployedCount) deployed")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(project.name)
        .task(id: reloadKey) { reloadSnapshot() }
    }

    @ViewBuilder
    private func projectSkillRow(_ row: ProjectSkillsSnapshot.Row) -> some View {
        if let skill = skills.first(where: { $0.id == row.skillID }) {
            Button(action: { onReveal(skill) }, label: {
                projectSkillLabel(row)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            })
            .buttonStyle(.plain)
        } else {
            projectSkillLabel(row)
        }
    }

    private func projectSkillLabel(_ row: ProjectSkillsSnapshot.Row) -> some View {
        HStack(spacing: Spacing.sm) {
            Label(row.name, systemImage: row.isDeployed ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(row.isDeployed ? .primary : .secondary)
            Spacer()
            Text(projectSkillStatus(row))
                .font(.caption)
                .foregroundStyle(row.isDeployed ? Color.secondary : Color.orange)
        }
    }

    private func projectSkillStatus(_ row: ProjectSkillsSnapshot.Row) -> String {
        switch (row.isDeployed, row.isIntended) {
        case (true, true): "Deployed · Assigned"
        case (true, false): "Deployed"
        case (false, true): "Assigned · Not deployed"
        case (false, false): ""
        }
    }

    @ViewBuilder
    private func categoriesContent(for project: Project) -> some View {
        if let identityKey = project.identityKey {
            let memberCategories = categories.filter { $0.projectKeys.contains(identityKey) }
            if memberCategories.isEmpty {
                Text("Not in any category")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: Spacing.xxs) {
                    ForEach(memberCategories) { category in
                        Text(category.name)
                    }
                }
            }
        } else {
            Text("Categories apply once identity resolves")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reloadSnapshot() {
        guard let project else { loaded = nil; return }
        loaded = Loaded(key: reloadKey,
                        snapshot: ProjectSkillsSnapshot.load(project: project, skills: skills,
                                                             categories: categories, platformVM: platformVM))
    }
}
