import SwiftUI

struct MachineListView: View {
    @Binding var entitySelection: EntitySelection?
    @Binding var searchText: String
    let machineStates: [MachineState]
    let localMachineID: String?
    let now: () -> Date
    @AppStorage(ListPreferenceKeys.showsLine2(.machines)) private var showsLine2 = true
    @AppStorage(ListPreferenceKeys.showsLine3(.machines)) private var showsLine3 = true

    private var filteredMachineStates: [MachineState] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return machineStates }
        return machineStates.filter { ListRows.machineMatchesSearch($0, query: query) }
    }

    var body: some View {
        let dates = ListDates(now: now())

        List(selection: $entitySelection) {
            ForEach(filteredMachineStates, id: \.machineID) { state in
                ListRowView(model: ListRows.machine(state, isThisMac: state.machineID == localMachineID,
                                                     dates: dates),
                            showsLine2: showsLine2, showsLine3: showsLine3)
                    .tag(EntitySelection.machine(state.machineID))
            }
        }
        .navigationTitle("Machines")
        .navigationSubtitle(ListSubtitle.text(total: machineStates.count, shown: filteredMachineStates.count,
                                              singular: "machine", plural: "machines"))
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        .searchable(text: $searchText, placement: .automatic, prompt: "Search")
        .overlay {
            if filteredMachineStates.isEmpty {
                if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView(
                        "No Machines Seen Yet",
                        systemImage: "display",
                        description: Text("Machines appear after they report sync state.")
                    )
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ListViewOptionsMenu(section: .machines, showsLine2: $showsLine2, showsLine3: $showsLine3)
            }
        }
    }
}
