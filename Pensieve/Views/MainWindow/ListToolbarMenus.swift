import SwiftUI

/// The Skills filter: Mail's groups, checkable, any-of within a group and AND across groups. The
/// symbol fills while a filter is active, Mail's "on" state for the same button. Session state only.
/// No menu indicator: Mail's and Notes' list-toolbar menus show the glyph alone.
struct SkillFilterMenu: View {
    @Binding var filter: SkillListFilter
    let tags: [String]
    let categories: [Category]
    /// False while `deploy-state.json` could not be read: the Deployed group is shown disabled with the
    /// reason, and the list view has already reset `filter.deploy` to `.any`.
    let deployStateAvailable: Bool

    var body: some View {
        Menu {
            if deployStateAvailable {
                Picker("Deployed on This Mac", selection: $filter.deploy) {
                    ForEach(DeployFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } else {
                Section("Deployed on This Mac") {
                    Text("Deploy state unavailable")
                }
            }
            Picker("Source", selection: $filter.source) {
                ForEach(SourceFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Section("Tags") {
                if tags.isEmpty {
                    Text("No Tags")
                } else {
                    ForEach(tags, id: \.self) { tag in
                        Toggle(tag, isOn: tagBinding(tag))
                    }
                }
            }
            Section("Categories") {
                if categories.isEmpty {
                    Text("No Categories")
                } else {
                    ForEach(categories) { category in
                        Toggle(category.name, isOn: categoryBinding(category.id))
                    }
                }
            }
            Divider()
            Button("Clear Filters") { filter = SkillListFilter() }
                .disabled(!filter.isActive)
        } label: {
            Label("Filter", systemImage: filter.isActive
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
        .menuIndicator(.hidden)
        .help("Filter")
    }

    private func tagBinding(_ tag: String) -> Binding<Bool> {
        Binding(
            get: { filter.tags.contains(tag) },
            set: { isOn in if isOn { filter.tags.insert(tag) } else { filter.tags.remove(tag) } }
        )
    }

    private func categoryBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { filter.categoryIDs.contains(id) },
            set: { isOn in if isOn { filter.categoryIDs.insert(id) } else { filter.categoryIDs.remove(id) } }
        )
    }
}

/// The View menu every list carries: the section's show-line toggles (named by content, from
/// `ListLineTitles`), then whatever the section adds — Skills adds Sort By. Mail's "•••" button,
/// glyph alone with no menu indicator.
struct ListViewOptionsMenu<Extra: View>: View {
    let section: SidebarSection
    @Binding var showsLine2: Bool
    @Binding var showsLine3: Bool
    @ViewBuilder let extra: () -> Extra

    init(section: SidebarSection, showsLine2: Binding<Bool>, showsLine3: Binding<Bool>,
         @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }) {
        self.section = section
        _showsLine2 = showsLine2
        _showsLine3 = showsLine3
        self.extra = extra
    }

    var body: some View {
        let titles = ListLineTitles.titles(for: section)
        Menu {
            Toggle(titles.line2, isOn: $showsLine2)
            if let line3 = titles.line3 {
                Toggle(line3, isOn: $showsLine3)
            }
            extra()
        } label: {
            Label("View Options", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("View Options")
    }
}

/// Skills' Sort By submenu: Notes' shape — the keys, a divider, then the two directions worded for
/// the selected key. Bound to the `@AppStorage` raw values so the choice persists app-wide.
struct SkillSortMenu: View {
    @Binding var sortKeyRaw: String
    @Binding var sortDirectionRaw: String

    private var sortKey: SkillSortKey { SkillSortKey(rawValue: sortKeyRaw) ?? .name }

    var body: some View {
        Menu("Sort By") {
            Picker("Sort Key", selection: $sortKeyRaw) {
                ForEach(SkillSortKey.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Picker("Direction", selection: $sortDirectionRaw) {
                ForEach(SortDirection.allCases) { Text(sortKey.directionTitle($0)).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}
