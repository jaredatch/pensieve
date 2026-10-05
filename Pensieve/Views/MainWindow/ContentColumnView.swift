import SwiftUI

struct ContentColumnView: View {
    let section: SidebarSection
    @Binding var entitySelection: EntitySelection?
    @Binding var selectedSkills: Set<Skill>
    @Binding var searchText: String
    let platformVM: PlatformViewModel
    let syncModel: SyncModel
    let library: SkillLibraryViewModel
    @Binding var skillFilter: SkillListFilter
    let machineStates: [MachineState]
    let localMachineID: String?
    let notifier: SyncStateNotifying
    let now: () -> Date
    let onAdd: (SidebarSection) -> Void
    let updateNoticeCount: Int
    let onOpenUpdates: () -> Void

    var body: some View {
        switch contentColumn(for: section) {
        case .skillList:
            SkillListView(
                searchText: $searchText,
                platformVM: platformVM,
                syncModel: syncModel,
                selectedSkills: $selectedSkills,
                library: library,
                filter: $skillFilter,
                updateNoticeCount: updateNoticeCount,
                onOpenUpdates: onOpenUpdates
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        case .projectList:
            ProjectListView(
                entitySelection: $entitySelection,
                searchText: $searchText,
                platformVM: platformVM,
                localMachineID: localMachineID,
                notifier: notifier,
                onAdd: { onAdd(.projects) },
                addsFenced: library.addsFenced
            )
        case .categoryList:
            CategoryListView(
                entitySelection: $entitySelection,
                searchText: $searchText,
                platformVM: platformVM,
                notifier: notifier,
                onAdd: { onAdd(.categories) },
                addsFenced: library.addsFenced
            )
        case .tagList:
            TagListView(entitySelection: $entitySelection, searchText: $searchText)
        case .machineList:
            MachineListView(
                entitySelection: $entitySelection,
                searchText: $searchText,
                machineStates: machineStates,
                localMachineID: localMachineID,
                now: now
            )
        }
    }
}
