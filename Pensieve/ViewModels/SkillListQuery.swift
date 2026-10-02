import Foundation

enum DeployFilter: String, CaseIterable, Identifiable {
    case any
    case deployed
    case notDeployed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: "Any"
        case .deployed: "Deployed"
        case .notDeployed: "Not Deployed"
        }
    }
}

enum SourceFilter: String, CaseIterable, Identifiable {
    case any
    case gitHub
    case local

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: "Any"
        case .gitHub: "GitHub"
        case .local: "Local"
        }
    }
}

/// The Skills filter menu's state: per-window session state (a `@State` in `ContentView`), never
/// persisted — like a Finder search it is cleared by reveal and gone with the window (PLAN-29).
struct SkillListFilter: Equatable {
    var deploy: DeployFilter = .any
    var source: SourceFilter = .any
    var tags: Set<String> = []
    var categoryIDs: Set<UUID> = []

    var isActive: Bool { self != SkillListFilter() }

    /// The same filter with selections the menu can no longer show removed — a tag no skill carries, a
    /// category that was deleted. The list view applies this whenever the live sets change (and on
    /// mount), so `isActive` and the filled symbol never claim a filter the query ignores.
    func pruned(liveTags: Set<String>, liveCategoryIDs: Set<UUID>) -> SkillListFilter {
        var copy = self
        copy.tags = tags.intersection(liveTags)
        copy.categoryIDs = categoryIDs.intersection(liveCategoryIDs)
        return copy
    }
}

enum SkillSortKey: String, CaseIterable, Identifiable {
    case name
    case created
    case updated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .created: "Date Created"
        case .updated: "Date Updated"
        }
    }

    /// Notes' words: dates read "Newest First" / "Oldest First", names "A to Z" / "Z to A".
    func directionTitle(_ direction: SortDirection) -> String {
        switch (self, direction) {
        case (.name, .ascending): "A to Z"
        case (.name, .descending): "Z to A"
        case (_, .ascending): "Oldest First"
        case (_, .descending): "Newest First"
        }
    }
}

enum SortDirection: String, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: String { rawValue }
}

/// `UserDefaults` keys for the persisted list preferences: the Skills sort is app-wide, the two
/// show-line toggles are per section. Read and written only through `@AppStorage` in the list views.
enum ListPreferenceKeys {
    static let sortKey = "skillList.sortKey"
    static let sortDirection = "skillList.sortDirection"

    static func showsLine2(_ section: SidebarSection) -> String { "list.\(section.rawValue).showsLine2" }
    static func showsLine3(_ section: SidebarSection) -> String { "list.\(section.rawValue).showsLine3" }
}

/// Everything the Skills list needs besides the rows themselves.
struct SkillListSpec: Equatable {
    var search = ""
    var filter = SkillListFilter()
    var sortKey = SkillSortKey.name
    var direction = SortDirection.ascending
}

/// Pure: search, filter, and sort the Skills list. The filter's groups AND together; within Tags and
/// within Categories a skill matches when it carries ANY selected value (Mail's filter semantics).
/// While the deploy index is unavailable the Deployed group is inert here as a last line of defense;
/// the menu disables that group and the list view resets it to `.any`, so the state never claims a
/// filter the data cannot answer (PLAN-24's tri-state rule).
enum SkillListQuery {
    static func apply(_ skills: [Skill], spec: SkillListSpec,
                      deployIndex: DeployIndex, categories: [Category]) -> [Skill] {
        let query = spec.search.trimmingCharacters(in: .whitespaces).lowercased()
        // A selection that no longer exists (a deleted category, a tag no skill carries) is ignored, not
        // applied: the menu cannot show it, so it must not silently hide every row. The view also prunes
        // such selections from the state so `isActive` and the filled symbol stay honest.
        let liveTags = spec.filter.tags.intersection(skills.flatMap(\.tags))
        let selectedCategories = categories.filter { spec.filter.categoryIDs.contains($0.id) }
        let categorySlugs = Set(selectedCategories.flatMap(\.skillSlugs))
        let matched = skills.filter { skill in
            matchesSearch(skill, query: query)
                && matchesSource(skill, filter: spec.filter.source)
                && matchesDeploy(skill, filter: spec.filter.deploy, index: deployIndex)
                && matchesTags(skill, tags: liveTags)
                && matchesCategories(skill, anySelected: !selectedCategories.isEmpty, slugs: categorySlugs)
        }
        return sorted(matched, by: spec.sortKey, direction: spec.direction)
    }

    static func sorted(_ skills: [Skill], by key: SkillSortKey, direction: SortDirection) -> [Skill] {
        let ascending = skills.sorted { lhs, rhs in
            switch key {
            case .name:
                return byName(lhs, rhs)
            case .created:
                return lhs.createdAt == rhs.createdAt ? byName(lhs, rhs) : lhs.createdAt < rhs.createdAt
            case .updated:
                return lhs.updatedAt == rhs.updatedAt ? byName(lhs, rhs) : lhs.updatedAt < rhs.updatedAt
            }
        }
        return direction == .ascending ? ascending : Array(ascending.reversed())
    }

    /// Finder's order: localized, numeric-aware, case-insensitive; the slug breaks exact ties so the
    /// order is total and stable across launches.
    private static func byName(_ lhs: Skill, _ rhs: Skill) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        return order == .orderedSame ? lhs.directoryName < rhs.directoryName : order == .orderedAscending
    }

    private static func matchesSearch(_ skill: Skill, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return skill.name.lowercased().contains(query)
            || skill.skillDescription.lowercased().contains(query)
            || skill.tags.contains { $0.lowercased().contains(query) }
    }

    private static func matchesSource(_ skill: Skill, filter: SourceFilter) -> Bool {
        switch filter {
        case .any: true
        case .gitHub: skill.hasLinkedOrigin
        case .local: !skill.hasLinkedOrigin
        }
    }

    private static func matchesDeploy(_ skill: Skill, filter: DeployFilter, index: DeployIndex) -> Bool {
        guard index.available else { return true }
        switch filter {
        case .any: return true
        case .deployed: return index.isDeployed(slug: skill.directoryName)
        case .notDeployed: return !index.isDeployed(slug: skill.directoryName)
        }
    }

    private static func matchesTags(_ skill: Skill, tags: Set<String>) -> Bool {
        tags.isEmpty || !tags.isDisjoint(with: skill.tags)
    }

    private static func matchesCategories(_ skill: Skill, anySelected: Bool, slugs: Set<String>) -> Bool {
        !anySelected || slugs.contains(skill.directoryName)
    }
}
