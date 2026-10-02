import SwiftUI
import SwiftData

struct SkillListView: View {
    @Binding var searchText: String
    let platformVM: PlatformViewModel
    let syncModel: SyncModel
    @Binding var selectedSkills: Set<Skill>
    @Bindable var library: SkillLibraryViewModel
    @Binding var filter: SkillListFilter
    let updateNoticeCount: Int
    let onOpenUpdates: () -> Void
    @State private var pendingDeletion: Skill?
    @AppStorage(ListPreferenceKeys.showsLine2(.skills)) private var showsLine2 = true
    @AppStorage(ListPreferenceKeys.showsLine3(.skills)) private var showsLine3 = true
    @AppStorage(ListPreferenceKeys.sortKey) private var sortKeyRaw = SkillSortKey.name.rawValue
    @AppStorage(ListPreferenceKeys.sortDirection) private var sortDirectionRaw = SortDirection.ascending.rawValue
    @Query(sort: \Skill.name) private var skills: [Skill]
    @Query(sort: \Project.name) private var projects: [Project]
    @Query(sort: \Category.name) private var categories: [Category]
    @Environment(\.modelContext) private var context

    private var sortKey: SkillSortKey { SkillSortKey(rawValue: sortKeyRaw) ?? .name }
    private var sortDirection: SortDirection { SortDirection(rawValue: sortDirectionRaw) ?? .ascending }

    private var visibleSkills: [Skill] {
        SkillListQuery.apply(
            skills,
            spec: SkillListSpec(search: searchText, filter: filter, sortKey: sortKey, direction: sortDirection),
            deployIndex: platformVM.deployIndex,
            categories: categories
        )
    }

    private var allTags: [String] {
        Array(Set(skills.flatMap(\.tags))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        let dates = ListDates(now: Date())
        let visible = visibleSkills

        List(visible, selection: $selectedSkills) { skill in
            skillRow(skill, dates: dates)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if updateNoticeCount > 0 {
                VStack(spacing: 0) {
                    SkillUpdatesBanner(count: updateNoticeCount, onOpen: onOpenUpdates)
                    Divider()
                }
                .background(.bar)
                // The list keeps a 12 pt top content inset of its own (measured 2026-09-12: the first
                // row's title sat 24.5 pt under the divider against the design's 12.5, the row's own 9
                // plus the cap). `contentMargins` does not reach a macOS List and a section header
                // brings its own 44 pt indent, so the inset is absorbed here: the banner reports 12 pt
                // less height than it draws, the list's inset lands under the bar, and the first row
                // seats at the divider as the design has it. Rows scroll under the banner either way.
                .padding(.bottom, -Spacing.md)
            }
        }
        .navigationTitle("Skills")
        .navigationSubtitle(ListSubtitle.text(total: skills.count, shown: visible.count,
                                              singular: "skill", plural: "skills"))
        .searchable(text: $searchText, placement: .automatic, prompt: "Search")
        .confirmationDialog(
            "Delete “\(pendingDeletion?.name ?? "")”?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { skill in
            Button("Delete", role: .destructive) {
                _ = SkillDeletionFlow.delete(skill: skill, library: library, platformVM: platformVM,
                                             projects: projects, context: context)
            }
        } message: { _ in
            Text(deletionMessage)
        }
        .onChange(of: allTags, initial: true) { _, tags in
            filter = filter.pruned(liveTags: Set(tags), liveCategoryIDs: Set(categories.map(\.id)))
        }
        .onChange(of: categories.map(\.id), initial: true) { _, ids in
            filter = filter.pruned(liveTags: Set(allTags), liveCategoryIDs: Set(ids))
        }
        .onChange(of: platformVM.deployIndex.available, initial: true) { _, available in
            if !available { filter.deploy = .any }
        }
        .onChange(of: visible.map(\.id), initial: true) { _, ids in
            let shown = Set(ids)
            selectedSkills = selectedSkills.filter { shown.contains($0.id) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SkillFilterMenu(filter: $filter, tags: allTags, categories: categories,
                                deployStateAvailable: platformVM.deployIndex.available)
            }
            ToolbarItem(placement: .primaryAction) {
                ListViewOptionsMenu(section: .skills, showsLine2: $showsLine2, showsLine3: $showsLine3) {
                    Divider()
                    SkillSortMenu(sortKeyRaw: $sortKeyRaw, sortDirectionRaw: $sortDirectionRaw)
                }
            }
        }
        .overlay {
            if visible.isEmpty {
                if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if filter.isActive {
                    ContentUnavailableView(
                        "No Matching Skills",
                        systemImage: "line.3.horizontal.decrease",
                        description: Text("Clear the filter to see every skill.")
                    )
                } else {
                    ContentUnavailableView(
                        "No Skills",
                        systemImage: "doc.text",
                        description: Text(library.storeUnreadable
                            ? "This library can't be read." : "Create a new skill or import existing ones.")
                    )
                }
            }
        }
    }

    private func skillRow(_ skill: Skill, dates: ListDates) -> some View {
        ListRowView(model: ListRows.skill(skill, deployIndex: platformVM.deployIndex, sortKey: sortKey,
                                          isConflicted: syncModel.conflictedSlugs.contains(skill.directoryName),
                                          dates: dates),
                    showsLine2: showsLine2, showsLine3: showsLine3)
            .tag(skill)
            .contextMenu {
                Button("Export SKILL.md…") { SkillExportPanel.present(skill: skill, library: library) }
                Button("Delete", role: .destructive) { pendingDeletion = skill }
            }
    }

    private var deletionMessage: String {
        SkillDeletionMessage.text(unsaved: pendingDeletion.map { library.hasUnsavedChanges(for: $0) } ?? false)
    }
}
