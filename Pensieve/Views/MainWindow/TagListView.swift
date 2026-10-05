import SwiftData
import SwiftUI

struct TagListView: View {
    @Binding var entitySelection: EntitySelection?
    @Binding var searchText: String
    @Query private var skills: [Skill]
    @AppStorage(ListPreferenceKeys.showsLine2(.tags)) private var showsLine2 = true
    @AppStorage(ListPreferenceKeys.showsLine3(.tags)) private var showsLine3 = true

    private var allTags: [String] {
        let tagSet = Set(skills.flatMap(\.tags))
        return tagSet.sorted()
    }

    private var filteredTags: [String] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return allTags }
        return allTags.filter { $0.lowercased().contains(query) }
    }

    var body: some View {
        List(selection: $entitySelection) {
            ForEach(filteredTags, id: \.self) { tag in
                ListRowView(model: ListRows.tag(tag, skills: skills),
                            showsLine2: showsLine2, showsLine3: showsLine3)
                    .tag(EntitySelection.tag(tag))
            }
        }
        .navigationTitle("Tags")
        .navigationSubtitle(ListSubtitle.text(total: allTags.count, shown: filteredTags.count,
                                              singular: "tag", plural: "tags"))
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        .searchable(text: $searchText, placement: .automatic, prompt: "Search")
        .overlay {
            if filteredTags.isEmpty {
                if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    EmptyStateView("No Tags", description: "Tags you add to a skill appear here.")
                } else {
                    EmptyStateView.search(text: searchText)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ListViewOptionsMenu(section: .tags, showsLine2: $showsLine2, showsLine3: $showsLine3)
            }
        }
    }
}
