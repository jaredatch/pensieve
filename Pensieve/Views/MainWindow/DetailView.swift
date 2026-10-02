import SwiftData
import SwiftUI

/// The skill detail: the header, the banner, the tab strip, and the selected tab. Every disk read
/// is in the snapshot, loaded off the render path; the tabs read it. The tab and the Content tab's file and
/// mode are this view's own state and persist across skills; a retained draft brings the source view back
/// (PLAN-33's rule for the Edit toggle, carried over).
struct DetailView: View {
    let skill: Skill
    let syncModel: SyncModel
    let tagsInUse: [String]
    let onResolve: () -> Void
    let onConnectToRepository: () -> Void
    let onOpenUpdates: () -> Void
    let onAddProject: () -> Void
    let onBulkDeploy: () -> Void
    @Bindable var library: SkillLibraryViewModel
    @Bindable var platformVM: PlatformViewModel
    @Bindable var provenance: SkillProvenanceViewModel
    @Bindable var upstreamHistory: UpstreamHistoryViewModel
    let intentDependencies: DeployIntentDependencies
    let machineStates: [MachineState]
    let localMachineID: String?

    @Environment(\.modelContext) private var context
    @Environment(\.controlActiveState) private var controlActiveState   // .key only while no sheet here holds the keyboard
    @Query(sort: \Project.name) private var projects: [Project]
    @State private var tab: DetailTab = .overview
    @State private var contentFile = "SKILL.md"
    @State private var contentMode: SkillContentPresentation.Mode = .rendered
    @State private var loaded: LoadedSnapshot?
    @State private var showDeleteConfirmation = false

    private struct LoadedSnapshot {
        let key: ReloadKey
        let snapshot: DetailContentSnapshot
    }

    /// Every signal the snapshot reloads on, so the keyed task is the one trigger and an update reloads once
    /// (Layer-1 over 34.2: a key and a change handler on the same revision read the bundle twice).
    private struct ReloadKey: Hashable {
        let skillID: UUID
        let reloadToken: Int
        let refreshCounter: Int
        let projectIDs: [UUID]
        /// The content-only signals: an app write (a Save, or a frontmatter-only rewrite whose stripped body is
        /// unchanged) and a watcher event — the only news of a change to a bundle file other than SKILL.md, which
        /// the library's body check reads as an echo. Deploy status does not depend on them.
        let appWriteRevision: Int
        let watcherEventSequence: UInt64

        /// The inputs deploy status is loaded for.
        func sameDeployInputs(as other: ReloadKey) -> Bool {
            skillID == other.skillID && reloadToken == other.reloadToken
                && refreshCounter == other.refreshCounter && projectIDs == other.projectIDs
        }
    }

    private var reloadKey: ReloadKey {
        ReloadKey(skillID: skill.id, reloadToken: library.reloadToken, refreshCounter: platformVM.refreshCounter,
                  projectIDs: projects.map(\.id), appWriteRevision: library.appWriteRevision,
                  watcherEventSequence: library.watcherEventSequence)
    }

    /// Empty (not stale) during the first frame after a skill switch; kept across the other key changes so
    /// text never flashes.
    private var snapshot: DetailContentSnapshot {
        if let loaded, loaded.key.skillID == skill.id { return loaded.snapshot }
        return DetailContentSnapshot()
    }

    /// Deploy status is meaningful only for the deploy inputs it was loaded for; a Save or a watcher event
    /// reloads the snapshot without disabling the switches for a frame.
    private var statusIsCurrent: Bool { loaded.map { $0.key.sameDeployInputs(as: reloadKey) } ?? false }
    private var skillProvenance: SkillProvenance? { provenance.provenance(for: skill) }

    var body: some View {
        // Share one resolved presentation between the layout and Content tab for this body evaluation.
        // Leave guards resolve current state when their handlers run.
        let presentation = SkillContentPresentation.resolve(
            selectedFile: contentFile,
            requestedMode: contentMode,
            inventory: snapshot.inventory
        )
        let contentOwnsScroller = Self.contentOwnsScroller(tab: tab, presentation: presentation)
        SkillDetailScrollLayout(
            skillID: skill.id,
            contentOwnsScroller: contentOwnsScroller
        ) {
            detailChrome
        } tabContent: {
            tabBody(presentation: presentation)
        }
        .onAppear { returnToDraftIfAny() }
        .onChange(of: skill.id) { _, _ in
            showDeleteConfirmation = false
            returnToDraftIfAny()
        }
        .toolbar { toolbarItems }
        .focusedSceneValue(\.deleteSelectedSkill, requestDelete)
        .focusedSceneValue(\.exportSelectedSkill, { SkillExportPanel.present(skill: skill, library: library) })
        .focusedSceneValue(\.skillDetailWindowIsKey, controlActiveState == .key)
        .confirmationDialog("Delete “\(skill.name)”?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let deleted = SkillDeletionFlow.delete(
                    skill: skill,
                    library: library,
                    platformVM: platformVM,
                    projects: projects,
                    context: context
                )
                if deleted { upstreamHistory.remove(skillID: skill.id) }
            }
        } message: {
            Text(SkillDeletionMessage.text(unsaved: library.hasUnsavedChanges(for: skill)))
        }
        .alert("Couldn't update deployment", isPresented: Binding(
            get: { platformVM.error != nil },
            set: { if !$0 { platformVM.error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(platformVM.error ?? "")
        }
        .navigationTitle(skill.name)
        .task(id: reloadKey) { reload() }
        .task(id: presentationID) {
            guard skill.hasLinkedOrigin else { return }
            await provenance.present(skillID: skill.id, context: context)
        }
        .onDisappear { provenance.cancelCheck(skillID: skill.id) }
    }

    @ViewBuilder private var detailChrome: some View {
        let showsUpdateBanner = UpdatesViewModel.isEligibleForUpdates(skill)
        SkillDetailHeader(skill: skill, provenance: skillProvenance, tagsInUse: tagsInUse,
                          syncConflicted: syncModel.conflictedSlugs.contains(skill.directoryName),
                          canResolve: syncModel.canResolve,
                          driftError: provenance.driftError(for: skill.id),
                          isChecking: provenance.isChecking(skillID: skill.id),
                          library: library, onResolve: onResolve, onCommitTags: commitTags)
        if showsUpdateBanner {
            SkillUpdateAvailableBanner(upstreamDate: skill.upstreamCommitDate, onOpenUpdates: onOpenUpdates)
        }
        DetailTabBar(selection: tab, onSelect: { select(tab: $0) })
            .padding(.horizontal, Spacing.lg)
            .padding(.top, showsUpdateBanner ? DesignTokens.bannerToStrip : 0)   // the header's inset is the gap
    }

    @ViewBuilder private func tabBody(presentation: SkillContentPresentation.Resolved) -> some View {
        switch tab {
        case .overview:
            SkillOverviewTab(skill: skill, snapshot: snapshot, provenance: skillProvenance,
                             installedCount: platformVM.deployablePlatforms(forProject: false).count, now: Date())
        case .deployments:
            SkillDeploymentsTab(skill: skill, snapshot: snapshot, statusIsCurrent: statusIsCurrent, projects: projects,
                                platformVM: platformVM, addsFenced: library.addsFenced,
                                intentDependencies: intentDependencies,
                                machineStates: machineStates,
                                localMachineID: localMachineID,
                                onAddProject: onAddProject)
        case .content:
            SkillContentTab(skill: skill, snapshot: snapshot, library: library, presentation: presentation,
                            onSelectFile: selectFile,
                            onSelectMode: selectMode)
        case .history:
            SkillHistoryTab(
                skill: skill,
                currentBody: snapshot.body,
                library: library,
                upstreamHistory: upstreamHistory,
                localRevision: UpstreamHistoryLocalRevision(
                    appWriteRevision: library.appWriteRevision,
                    watcherEventSequence: library.watcherEventSequence
                ),
                onOpenUpdates: onOpenUpdates,
                onUpdateCheck: { skillID in
                    provenance.checkForUpdates(skillID: skillID, context: context)
                }
            )
                .environment(\.skillHistorySyncSignal, SkillHistorySyncSignal(syncModel.state))
        }
    }

    // MARK: - The ways out (each through PLAN-33's gate; a clean editor proceeds at once)

    private func select(tab new: DetailTab) {
        guard new != tab else { return }
        guard isEditingSkillSource else { tab = new; return }
        library.confirmLeaving(skill) { proceed in if proceed { tab = new } }
    }

    private func selectFile(_ path: String) {
        let presentation = currentContentPresentation
        guard path != presentation.choice.relativePath else {
            contentFile = path   // the shown file: nothing to leave, but the pick sticks
            return
        }
        guard Self.isEditingSkillSource(tab: tab, presentation: presentation) else {
            contentFile = path
            return
        }
        library.confirmLeaving(skill) { proceed in if proceed { contentFile = path } }
    }

    private func selectMode(_ new: SkillContentPresentation.Mode) {
        guard new != contentMode else { return }
        guard isEditingSkillSource else { contentMode = new; return }
        library.confirmLeaving(skill) { proceed in if proceed { contentMode = new } }
    }

    private var currentContentPresentation: SkillContentPresentation.Resolved {
        SkillContentPresentation.resolve(
            selectedFile: contentFile,
            requestedMode: contentMode,
            inventory: snapshot.inventory
        )
    }

    private var isEditingSkillSource: Bool {
        Self.isEditingSkillSource(tab: tab, presentation: currentContentPresentation)
    }

    /// A retained draft brings its editor back: after a section switch, a search, or a selection the sheet's
    /// Cancel reversed, the detail is rebuilt on its last tab and would hide the draft.
    private func returnToDraftIfAny() {
        guard library.hasUnsavedChanges(for: skill) else { return }
        tab = .content
        contentFile = "SKILL.md"
        contentMode = .source
    }

    /// Delete asks its confirmation and nothing else: deleting is discarding, and `deleteSkillEntry` drops the
    /// draft only once the files are provably gone, so a refused delete keeps it (PLAN-33's close).
    private func requestDelete() { showDeleteConfirmation = true }

    private func reload() {
        let key = reloadKey
        loaded = LoadedSnapshot(key: key, snapshot: DetailContentSnapshot.load(
            skill: skill, projects: projects, library: library, platformVM: platformVM))
    }

    private func commitTags(_ tags: [String]) {
        guard !skill.isDeleted else { return }   // a commit racing a delete writes nothing
        library.updateMetadata(skill, tags: tags, scope: skill.scope, context: context)
    }

    static func contentOwnsScroller(
        tab: DetailTab,
        presentation: SkillContentPresentation.Resolved
    ) -> Bool {
        tab == .content && presentation.ownsScroller
    }

    static func isEditingSkillSource(
        tab: DetailTab,
        presentation: SkillContentPresentation.Resolved
    ) -> Bool {
        tab == .content && presentation.choice.isSkillFile && presentation.shownMode == .source
    }

    private var presentationID: String {
        [
            skill.id.uuidString,
            skill.installedOriginData?.base64EncodedString() ?? "unversioned",
            String(skill.updatedAt.timeIntervalSinceReferenceDate),
            String(library.reloadToken)
        ].joined(separator: ":")
    }
}

private extension DetailView {
    @ToolbarContentBuilder var toolbarItems: some ToolbarContent {
        ToolbarItem {
            SkillMoreMenu(
                state: SkillMoreMenuState(skill: skill, provenance: skillProvenance,
                                          isChecking: provenance.isChecking(skillID: skill.id)),
                onReveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.canonicalDir)]) },
                onViewOnGitHub: {
                    if let url = skillProvenance?.skillURL ?? skillProvenance?.repositoryURL { NSWorkspace.shared.open(url) }
                },
                onCopyPath: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(skill.canonicalDir, forType: .string)
                },
                onCheckForUpdates: checkForUpdates,
                onConnect: onConnectToRepository,
                onDeploy: onBulkDeploy,
                onDelete: requestDelete
            )
        }
    }

    func checkForUpdates() {
        provenance.checkForUpdates(skillID: skill.id, context: context)
        upstreamHistory.invalidateForManualCheck(skillID: skill.id)
    }
}

/// The detail owns the vertical scroller so its chrome and tab content travel as one column. Source content
/// normally fills the viewport around a WKWebView scroller; the column itself scrolls only when chrome overflows.
struct SkillDetailScrollLayout<Chrome: View, TabContent: View>: View {
    let skillID: UUID
    let contentOwnsScroller: Bool
    let chrome: Chrome
    let tabContent: TabContent

    init(
        skillID: UUID,
        contentOwnsScroller: Bool,
        @ViewBuilder chrome: () -> Chrome,
        @ViewBuilder tabContent: () -> TabContent
    ) {
        self.skillID = skillID
        self.contentOwnsScroller = contentOwnsScroller
        self.chrome = chrome()
        self.tabContent = tabContent()
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    column
                        .frame(minHeight: geometry.size.height, alignment: .topLeading)
                        .id(ScrollAnchor.top)
                }
                // A source editor gets the wheel while everything fits. If expanded chrome is taller than
                // the viewport, the column becomes scrollable so its file row and editor cannot be stranded.
                .scrollBounceBehavior(contentOwnsScroller ? .basedOnSize : .automatic, axes: .vertical)
                .onChange(of: skillID) { _, _ in
                    proxy.scrollTo(ScrollAnchor.top, anchor: .top)
                }
            }
        }
    }

    private enum ScrollAnchor {
        case top
    }

    private var column: some View {
        VStack(spacing: 0) {
            chrome
            tabContent
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The delete confirmation's message, shared by the detail and the list's context menu; an unsaved draft
/// is named, since Delete no longer asks the unsaved-changes sheet first.
enum SkillDeletionMessage {
    static func text(unsaved: Bool) -> String {
        let base = "This removes the skill from your library, unlinks it from the agents Pensieve linked it to "
            + "on this Mac (the agents found at launch, in your registered projects), and retracts it "
            + "from every machine. Compiled Cursor rules are left in place."
        return unsaved ? base + " Unsaved changes to SKILL.md will be lost." : base
    }
}
