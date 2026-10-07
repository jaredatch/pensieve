import SwiftUI
import SwiftData
import os
struct ContentView: View {
    @State private var section: SidebarSection = .skills
    @State private var entitySelection: EntitySelection?
    @State private var selectedSkills: Set<Skill> = []
    @State private var searchText = ""
    @State private var skillFilter = SkillListFilter()
    @State private var createdSkill: Skill?
    @State private var importVM: ImportViewModel
    @State private(set) var installVM: SkillInstallViewModel
    @State private var updatesVM: UpdatesViewModel
    @State private var showImportWizard = false
    @State private var showFolderImport = false
    @State private var folderImportNotice: String?
    @State private var showGitHubInstall = false
    @State private var showBulkDeploy = false
    @State private var addSheet: AddSheet?
    @State private var createdEntity: EntitySelection?
    @State private var showConflictResolution = false
    @State private var machineStates: [MachineState] = []
    @State private var localMachineID: String?
    @State private var remoteProjects = RemoteProjectsModel()
    @State private var remoteRetractions = RemoteRetractionStore()
    private let notifier: SyncStateNotifying
    private let machineDependencies: MachineObservabilityDependencies

    init(
        installService: SkillInstallServiceProtocol,
        notifier: @escaping SyncStateNotifying = SyncStateNotifier.suppressed,
        echoRegistrar: @escaping SyncWriteEchoRegistering = SyncWriteEchoRegistrar.suppressed,
        bodyWriteRegistration: SyncBodyWriteRegistration = .suppressed,
        updatesModel: UpdatesViewModel,
        machineDependencies: MachineObservabilityDependencies = .live
    ) {
        self.notifier = notifier
        self.machineDependencies = machineDependencies
        _importVM = State(initialValue: ImportViewModel(
            manifestService: ManifestService(), notifier: notifier,
            echoRegistrar: echoRegistrar))
        _installVM = State(initialValue: SkillInstallViewModel(
            service: installService, notifier: notifier,
            echoRegistrar: echoRegistrar, bodyWriteRegistration: bodyWriteRegistration))
        _updatesVM = State(initialValue: updatesModel)
    }
    @Query private var skills: [Skill]
    @Query(sort: \Project.name) private var projects: [Project]
    @Query(sort: \Category.name) private var categories: [Category]
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    var body: some View {
        @Bindable var library = runtime.library
        let intentDependencies = DeployIntentDependencies.live(
            identity: machineDependencies.identity,
            stateService: machineDependencies.stateService,
            root: machineDependencies.root,
            lockPath: runtime.syncLockPath,
            notifier: notifier,
            reconcile: runtime.reconcileIntent,
            remoteRetractions: remoteRetractions
        )
        let splitView = NavigationSplitView {
            SidebarView(
                section: Binding(get: { section }, set: { section = $0 ?? section }),
                showsMachines: showsMachines
            )
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 260)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if syncModel.isConfigured {
                        SyncStatusView(model: syncModel, onResolve: { showConflictResolution = true })
                    }
                }
        } content: {
            ContentColumnView(
                section: section,
                entitySelection: $entitySelection,
                selectedSkills: $selectedSkills,
                searchText: $searchText,
                platformVM: platformVM,
                syncModel: syncModel,
                library: library,
                skillFilter: $skillFilter,
                machineStates: machineStates,
                remoteProjects: remoteProjects.projects,
                localMachineID: localMachineID,
                notifier: notifier,
                now: machineDependencies.now,
                onAdd: presentAdd,
                updateNoticeCount: updateNoticeCount,
                onOpenUpdates: presentUpdates
            )
        } detail: {
            DetailColumnView(
                section: section,
                entitySelection: entitySelection,
                selectedSkills: selectedSkills,
                skills: skills,
                skillsEmpty: skills.isEmpty,
                projects: projects,
                platformVM: platformVM,
                syncModel: syncModel,
                library: library,
                provenance: runtime.provenanceVM,
                upstreamHistory: runtime.upstreamHistory,
                machineStates: machineStates,
                remoteProjects: remoteProjects.projects,
                localMachineID: localMachineID,
                notifier: notifier,
                intentDependencies: intentDependencies,
                now: machineDependencies.now,
                onResolve: { showConflictResolution = true },
                onConnectToRepository: presentRepositoryConnection,
                onBulkDeploy: { showBulkDeploy = true },
                onOpenUpdates: presentUpdates,
                updateRouting: updateRouting,
                onImport: { showImportWizard = true },
                onImportFolder: importFromFolder,
                onCreate: { library.showCreateSheet = true },
                onAddFromGitHub: presentGitHubInstall,
                onAdd: presentAdd,
                onReveal: { skill in
                    revealSkill(
                        skill, section: &section, entity: &entitySelection,
                        selectedSkills: &selectedSkills, filter: &skillFilter, searchText: &searchText
                    )
                }
            )
        }

        let sheetView = splitView
            .frame(minWidth: DesignTokens.mainWindowMinimumWidth, minHeight: DesignTokens.mainWindowMinimumHeight)
        .sheet(isPresented: $library.showCreateSheet, onDismiss: revealCreatedSkill) {
            CreateSkillSheet(library: library, onCreated: { createdSkill = $0 })
        }
        .sheet(isPresented: $showImportWizard) {
            ImportWizardView(importVM: importVM, writesAllowed: !library.addsFenced)
        }
        .modifier(FolderImportPresentation(
            showWizard: $showFolderImport, notice: $folderImportNotice, importVM: importVM,
            writesAllowed: !library.addsFenced, onImportRequested: importFromFolder
        ))
        .modifier(UnsavedChangesNavigationGuard(
            library: library, section: $section, entitySelection: $entitySelection,
            selectedSkills: $selectedSkills, filter: $skillFilter, searchText: $searchText
        ))
        .sheet(
            isPresented: $showGitHubInstall,
            onDismiss: finishGitHubInstall,
            content: { AddFromGitHubSheet(model: installVM) }
        )
        .sheet(isPresented: $updatesVM.isPresented, onDismiss: updatesVM.reset) {
            updateRouting.sheet
        }
        .sheet(isPresented: $showBulkDeploy) {
            BulkDeploySheet(
                skills: Array(selectedSkills),
                platformVM: platformVM,
                intentDependencies: intentDependencies
            )
        }
        .sheet(item: $addSheet, onDismiss: revealCreatedEntity) {
            AddEntitySheet(kind: $0, notifier: notifier, intentReconciler: runtime.reconcileIntent,
                           onCreated: { createdEntity = $0 })
        }
        .sheet(isPresented: $showConflictResolution, onDismiss: finishConflictResolution, content: {
            ConflictResolutionView(
                model: ConflictResolutionModel(onResolutionStarted: runtime.beginConflictResolution),
                library: library,
                notifier: notifier,
                onDismiss: { showConflictResolution = false }
            )
        })
        let appearedView = sheetView
            .onAppear {
            Task { await runtime.mainWindowAppeared() }
            let openMainWindow = openWindow
            runtime.registerOpenMainWindowAction {
                openMainWindow(id: "main")
            }
            runtime.performLaunchWorkIfNeeded(
                context: modelContext,
                beforeStartingWatcher: runtime.checkForSkillUpdatesIfDue
            )
            let skillCount = (try? modelContext.fetchCount(FetchDescriptor<Skill>())) ?? skills.count
            if !library.addsFenced, runtime.shouldAutoShowImportWizard(skillCount: skillCount) {
                showImportWizard = true
            }
            reloadMachineStates()
        }
        let selectionView = appearedView
            .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { runtime.checkForSkillUpdatesIfDue() }
        }
        .onChange(of: skills.map(\.id)) { _, currentIDs in
            let ids = Set(currentIDs)
            selectedSkills = Set(selectedSkills.filter { ids.contains($0.id) })
            runtime.upstreamHistory.retain(skillIDs: ids)
        }
        .onChange(of: section) { old, new in
            entitySelection = nil
            if clearsSkillSelection(movingFrom: old, to: new) { selectedSkills = [] }
            searchText = ""
        }

        let entityView = selectionView
            .onChange(of: remoteProjectInputs, initial: true) { _, inputs in
            if remoteProjects.refresh(inputs, now: machineDependencies.now) { pruneEntitySelection() }
        }
        .onChange(of: entityKeys) { _, _ in
            pruneEntitySelection()
        }
        .onChange(of: showsMachines) { _, shows in
            section = availableSection(section, showsMachines: shows)
        }

        let lifecycleView = entityView
            .onChange(of: library.addsFenced) { _, fenced in
            if fenced { library.showCreateSheet = false; showImportWizard = false; showFolderImport = false; addSheet = nil }
        }
        .onChange(of: syncModel.state) { _, _ in
            reloadMachineStates()
        }

        lifecycleView
            .alert("Update check failed", isPresented: Binding(
            get: { runtime.updateCheckAlertError != nil },
            set: { if !$0 { runtime.clearUpdateCheckAlert() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(runtime.updateCheckAlertError ?? "")
        }
        .alert(library.deletionNotice?.title ?? "", isPresented: Binding(
            get: { library.deletionNotice != nil },
            set: { if !$0 { library.deletionNotice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.deletionNotice?.message ?? "")
        }
        .focusedSceneValue(\.addSkillFromGitHub, presentGitHubInstall)
    }
}
private extension ContentView {
    /// Arrays keep the render-pass key cheap. The change handler builds sets only when inputs change.
    private struct EntityKeys: Equatable {
        let projectIDs: [UUID], categoryIDs: [UUID]
        let tags: [String]
    }
    private var entityKeys: EntityKeys {
        EntityKeys(projectIDs: projects.map(\.id), categoryIDs: categories.map(\.id),
                   tags: skills.flatMap(\.tags))
    }
    private var remoteProjectInputs: RemoteProjectsModel.Inputs {
        RemoteProjectsModel.Inputs(machineStates: machineStates,
                                   localProjectIdentityKeys: projects.compactMap(\.identityKey),
                                   localMachineID: localMachineID)
    }
    private func pruneEntitySelection() {
        entitySelection = prunedEntitySelection(
            entitySelection, projectIDs: Set(projects.map(\.id)), categoryIDs: Set(categories.map(\.id)),
            machineIDs: Set(machineStates.map(\.machineID)), tags: Set(skills.flatMap(\.tags)),
            remoteProjectKeys: Set(remoteProjects.projects.map(\.identityKey))
        )
    }
    var library: SkillLibraryViewModel { runtime.library }
    var platformVM: PlatformViewModel { runtime.platformVM }
    var syncModel: SyncModel { runtime.syncModel }
    var showsMachines: Bool { syncModel.isConfigured || !machineStates.isEmpty }
    private func finishConflictResolution() {
        Task { await runtime.conflictResolutionDismissed() }
        library.refreshQuarantine(context: modelContext)
    }
    /// Import from Folder…: the + menu item and File › Import from Folder… (⌘⇧I) both land here.
    func importFromFolder() {
        // One import presentation at a time: both wizards read importVM's single result set.
        guard !library.addsFenced, !showImportWizard, !showFolderImport else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a skill folder, or a folder of skills"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !library.addsFenced, !showImportWizard else { return }   // re-checked: the panel was modal for a while
        let shown = (url.path as NSString).abbreviatingWithTildeInPath
        switch importVM.scanFolder(url.path) {
        case .found:
            showFolderImport = true
        case .nothingFound:
            folderImportNotice = importVM.nothingFoundMessage(folder: shown)
        case .insideLibrary:
            folderImportNotice = "\(shown) is Pensieve's own library. Its skills are already here."
        }
    }
    func presentGitHubInstall() {
        guard !library.addsFenced else { return }
        installVM.reset()
        showGitHubInstall = true
    }
    func presentRepositoryConnection(for skill: Skill) {
        installVM.prepareAdoption(of: skill)
        showGitHubInstall = true
    }
    func presentAdd(for section: SidebarSection) {
        guard !library.addsFenced else { return }
        switch section {
        case .skills: library.showCreateSheet = true
        case .projects: addSheet = .project
        case .categories: addSheet = .category
        case .tags, .machines: break
        }
    }
    /// New Skill selects what it creates, once its sheet is gone: a selection change while the sheet is up would
    /// present the unsaved-changes sheet over it, since the navigation guard asks on every way out of a draft.
    func revealCreatedSkill() {
        guard let skill = createdSkill else { return }
        createdSkill = nil
        revealSkill(skill, section: &section, entity: &entitySelection,
                    selectedSkills: &selectedSkills, filter: &skillFilter, searchText: &searchText)
    }
    func revealCreatedEntity() {
        selectionAfterCreating(createdEntity, in: section, entity: &entitySelection, searchText: &searchText)
        createdEntity = nil
    }
    func presentUpdates() {
        updateRouting.presentUpdates()
    }
    private var updateRouting: UpdateReviewRouting {
        UpdateReviewRouting(preview: runtime.viewChanges, updates: updatesVM, library: library,
                            context: modelContext, openWindow: { openWindow(id: $0) })
    }
    func finishGitHubInstall() {
        for adoption in installVM.completedAdoptions {
            let adoptedSkill = skills.first(where: { $0.id == adoption.skillID })
                ?? selectedSkills.first(where: { $0.id == adoption.skillID })
            if let adoptedSkill {
                runtime.provenanceVM.recordAdoption(adoption, on: adoptedSkill)
            }
        }
        installVM.reset()
    }
    var updateNoticeCount: Int {
        UpdatesViewModel.noticeCount(in: skills)
    }

    func reloadMachineStates() {
        do {
            localMachineID = try machineDependencies.identity.identifier()
        } catch {
            localMachineID = nil
            Logger(subsystem: "com.jaredatch.pensieve", category: "machines")
                .warning("Local machine identity unavailable: \(error.localizedDescription, privacy: .public)")
        }
        machineStates = machineDependencies.stateService.readAll(fromRoot: machineDependencies.root)
        remoteRetractions.observe(machineStates)
    }
}
