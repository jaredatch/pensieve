import SwiftUI

struct DetailColumnView: View {
    let section: SidebarSection
    let entitySelection: EntitySelection?
    let selectedSkills: Set<Skill>
    let skills: [Skill]
    let skillsEmpty: Bool
    let projects: [Project]
    let platformVM: PlatformViewModel
    let syncModel: SyncModel
    let library: SkillLibraryViewModel
    let provenance: SkillProvenanceViewModel
    let upstreamHistory: UpstreamHistoryViewModel
    let machineStates: [MachineState]
    let localMachineID: String?
    let notifier: SyncStateNotifying
    let intentDependencies: DeployIntentDependencies
    let now: () -> Date
    let onResolve: () -> Void
    let onConnectToRepository: (Skill) -> Void
    let onBulkDeploy: () -> Void
    let onOpenUpdates: () -> Void
    let onImport: () -> Void
    let onImportFolder: () -> Void
    let onCreate: () -> Void
    let onAddFromGitHub: () -> Void
    let onAdd: (SidebarSection) -> Void
    let onReveal: (Skill) -> Void

    var body: some View {
        content
            .toolbar {
                ToolbarItem { addControl }
                ToolbarItem { Spacer() }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch detailColumn(for: section, entity: entitySelection,
                            selectedSkillCount: selectedSkills.count,
                            skillsEmpty: skillsEmpty) {
        case .project(let id):
            ProjectDetailView(
                projectID: id, platformVM: platformVM, library: library, onReveal: onReveal
            )
                .id(id)
        case .category(let id):
            CategoryDetailView(
                categoryID: id, platformVM: platformVM, notifier: notifier, onReveal: onReveal
            )
                .id(id)
        case .scenario(let id):
            ScenarioDetailView(
                scenarioID: id, platformVM: platformVM, notifier: notifier, onReveal: onReveal
            )
                .id(id)
        case .machine(let id):
            machineDetail(id)
        case .tag(let name):
            TagDetailView(tag: name, skills: skills, onReveal: onReveal)
                .id(name)
        case .skill:
            if let skill = selectedSkills.first {
                skillDetail(skill)
            } else {
                selectSkillPrompt
            }
        case .bulk:
            bulkPlaceholder
        case .emptyNoSkills:
            if library.storeUnreadable {
                ContentUnavailableView(
                    "Can't Read This Library", systemImage: "exclamationmark.triangle",
                    description: Text("It may have been written by a newer version of Pensieve. "
                        + "Update Pensieve, then relaunch to see your skills and add new ones.")
                )
            } else {
                ContentUnavailableView {
                    Label("No Skills Yet", systemImage: "sparkles")
                } description: {
                    Text("Import existing skills or create your first one.")
                } actions: {
                    Button("Find Skills on This Mac", action: onImport)
                        .buttonStyle(.borderedProminent).disabled(library.addsFenced)
                    Button("Import from Folder…", action: onImportFolder)
                        .buttonStyle(.bordered).disabled(library.addsFenced)
                    Button("Create Skill", action: onCreate)
                        .buttonStyle(.bordered).disabled(library.addsFenced)
                }
            }
        case .selectSkillPrompt:
            selectSkillPrompt
        case .selectEntityPrompt(let section):
            selectEntityPrompt(section)
        }
    }

    /// Mail's compose slot: the leading item of the detail toolbar, adding the kind of thing the sidebar
    /// section holds. Skills is one menu button, `+` with its indicator: a click opens New Skill, the
    /// two import routes, and GitHub (one control, not a split button; ⌘N is the
    /// menu bar's). Tags derive from skills and Machines report themselves, so those sections
    /// add nothing.
    @ViewBuilder
    private var addControl: some View {
        switch section {
        case .skills:
            Menu {
                Button("New Skill", action: onCreate)
                    .keyboardShortcut("n", modifiers: .command)
                Divider()
                Button("Import from Folder…", action: onImportFolder)
                Button("Find Skills on This Mac…", action: onImport)
                Button("Add Skill from GitHub…", action: onAddFromGitHub)
            } label: {
                Label("Add Skill", systemImage: "plus")
            }
            .disabled(library.addsFenced)
            .help("Add Skill")
        case .projects:
            Button { onAdd(.projects) } label: { Label("Add Project", systemImage: "plus") }
                .disabled(library.addsFenced)
                .help("Add Project")
        case .categories:
            Button { onAdd(.categories) } label: { Label("Add Category", systemImage: "plus") }
                .disabled(library.addsFenced)
                .help("Add Category")
        case .scenarios:
            Button { onAdd(.scenarios) } label: { Label("Add Scenario", systemImage: "plus") }
                .disabled(library.addsFenced)
                .help("Add Scenario")
        case .tags, .machines:
            EmptyView()
        }
    }

    @ViewBuilder
    private func skillDetail(_ skill: Skill) -> some View {
        if library.libraryUnavailable {
            ContentUnavailableView(
                "Library Unavailable", systemImage: "exclamationmark.triangle",
                description: Text("Pensieve couldn't read the skill library. Relaunch to try again.")
            )
        } else if library.pendingRowCleanup.contains(skill.id) {
            ContentUnavailableView(
                "Skill Files Unavailable", systemImage: "doc.questionmark",
                description: Text(
                    "This skill's SKILL.md is missing, unreadable, or isn't a regular file. "
                        + "Delete the skill from the list, or restore the file and relaunch Pensieve."
                )
            )
        } else {
            DetailView(
                skill: skill,
                syncModel: syncModel,
                tagsInUse: Array(Set(skills.flatMap(\.tags)))
                    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
                onResolve: onResolve,
                onConnectToRepository: { onConnectToRepository(skill) },
                onOpenUpdates: onOpenUpdates,
                onAddProject: { onAdd(.projects) },
                onBulkDeploy: onBulkDeploy,
                library: library,
                platformVM: platformVM,
                provenance: provenance,
                upstreamHistory: upstreamHistory,
                intentDependencies: intentDependencies,
                machineStates: machineStates,
                localMachineID: localMachineID
            )
        }
    }

    private var bulkPlaceholder: some View {
        ContentUnavailableView {
            Label("\(selectedSkills.count) Skills Selected", systemImage: "checklist")
        } description: {
            Text("Deploy or remove these skills across your agents in one pass.")
        } actions: {
            Button("Deploy to Agents…", action: onBulkDeploy)
                .buttonStyle(.borderedProminent)
        }
    }

    private var selectSkillPrompt: some View {
        ContentUnavailableView {
            Label("Select a Skill", systemImage: "doc.text")
        } description: {
            Text("Choose a skill from the list, or press ⌘N to create one.")
        }
    }

    private func selectEntityPrompt(_ section: SidebarSection) -> some View {
        let prompt = entityPrompt(for: section)
        return ContentUnavailableView(prompt.title, systemImage: prompt.symbol)
    }

    private func entityPrompt(for section: SidebarSection) -> (title: String, symbol: String) {
        switch section {
        case .skills: ("Select a Skill", "doc.text")
        case .projects: ("Select a Project", "folder")
        case .categories: ("Select a Category", "square.stack")
        case .scenarios: ("Select a Scenario", "square.grid.2x2")
        case .tags: ("Select a Tag", "tag")
        case .machines: ("Select a Machine", "display")
        }
    }

    @ViewBuilder
    private func machineDetail(_ id: String) -> some View {
        if let state = machineStates.first(where: { $0.machineID == id }) {
            MachineDetailView(
                state: state,
                skills: skills,
                localProjectIdentityKeys: Set(projects.compactMap(\.identityKey)),
                localMachineID: localMachineID,
                now: now,
                onReveal: onReveal
            )
            .id("\(id)|\(state.publishedAt.timeIntervalSinceReferenceDate)")
        } else {
            ContentUnavailableView("Machine Not Found", systemImage: "display")
        }
    }
}
