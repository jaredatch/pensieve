import Foundation

/// One middle-column row in Mail's anatomy: line 1 is the bold title with a secondary
/// trailing text (Mail's date column) and an optional glyph before it; line 2 is primary text; line 3
/// is secondary text. A `nil` line is absent for the whole section (Tags has no third line); an empty
/// fact is a placeholder string ("Not deployed", "No projects") so every row in a list keeps one
/// height, the way Mail prints "…" for a message with no preview text.
struct ListRowModel: Equatable {
    enum Glyph: Equatable {
        /// GitHub's mark (asset `github-mark`, a template image) in the label color — black or white per
        /// appearance, the two colors GitHub's brand guidelines permit; it is never tinted.
        case gitHub
        /// An upstream update is waiting: the accent `arrow.down.circle.fill` takes the slot. Only a
        /// GitHub skill can have one, so the origin is implied. The banner's rule: a failed last check
        /// withdraws it until a check succeeds.
        case updateAvailable
        /// The orange warning triangle: this skill has a sync conflict. Takes the slot over everything.
        case conflict

        var accessibilityLabel: String {
            switch self {
            case .gitHub: "From GitHub"
            case .updateAvailable: "From GitHub; update available"
            case .conflict: "Sync conflict"
            }
        }
    }

    var title: String
    var trailingText: String?
    var glyph: Glyph?
    var line2: String?
    var line3: String?
    /// Paths truncate in the middle, as Finder's do; everything else truncates at the tail.
    var line2TruncatesMiddle = false
}

/// Pure row builders, one per section, so the mapping from model objects to the three lines is
/// tested apart from SwiftUI and SwiftData. Names lists are joined with ", " and left for the view
/// to truncate to one line.
enum ListRows {
    static func skill(_ skill: Skill, deployIndex: DeployIndex, sortKey: SkillSortKey,
                      isConflicted: Bool, dates: ListDates) -> ListRowModel {
        let glyph: ListRowModel.Glyph?
        if isConflicted {
            glyph = .conflict
        } else if skill.hasLinkedOrigin {
            // The banner's rule: a failed check withdraws it.
            glyph = UpdatesViewModel.isEligibleForUpdates(skill) ? .updateAvailable : .gitHub
        } else {
            glyph = nil
        }
        return ListRowModel(
            title: skill.name,
            trailingText: dates.mailStyle(sortKey == .created ? skill.createdAt : skill.updatedAt),
            glyph: glyph,
            line2: deployIndex.summary(for: skill.directoryName),
            line3: skill.skillDescription.isEmpty ? "No description" : skill.skillDescription
        )
    }

    static func project(_ project: Project, deployIndex: DeployIndex, homeDirectory: String) -> ListRowModel {
        let count = deployIndex.skillCount(inProjectKey: project.identityKey ?? project.path)
        return ListRowModel(
            title: project.name,
            trailingText: deployIndex.available ? counted(count, "skill") : "Deploy state unavailable",
            line2: abbreviatePath(project.path, homeDirectory: homeDirectory),
            line3: identityLine(project),
            line2TruncatesMiddle: true
        )
    }

    static func category(_ category: Category, projects: [Project], skills: [Skill]) -> ListRowModel {
        let keys = Set(category.projectKeys)
        let projectNames = projects.filter { $0.identityKey.map(keys.contains) ?? false }.map(\.name)
        let projectsLine: String
        if !projectNames.isEmpty {
            projectsLine = joined(projectNames)
        } else if keys.isEmpty {
            projectsLine = "No projects"
        } else {
            projectsLine = "Not registered on this Mac"
        }
        return ListRowModel(
            title: category.name,
            trailingText: counted(keys.count, "project") + " · " + counted(category.skillSlugs.count, "skill"),
            line2: projectsLine,
            line3: skillNamesLine(category.skillSlugs, skills: skills)
        )
    }

    static func tag(_ tag: String, skills: [Skill]) -> ListRowModel {
        let carriers = skills.filter { $0.tags.contains(tag) }
        return ListRowModel(
            title: tag,
            trailingText: counted(carriers.count, "skill"),
            line2: carriers.isEmpty ? "No skills" : joined(carriers.map(\.name)),
            line3: nil
        )
    }

    /// Line 3 counts distinct skill slugs realized at each scope, never registered projects.
    static func machine(_ state: MachineState, isThisMac: Bool, dates: ListDates) -> ListRowModel {
        let agents = state.agents.map { rawValue in
            PlatformTarget(rawValue: rawValue)?.displayName
                ?? PublishedStringSanitizer.name(rawValue, fallback: "Agent")
        }
        let userWide = Set(state.userDeploys.map(\.slug)).count
        let projectOnly = Set(state.projectDeploys.map(\.slug)).count
        let name = PublishedStringSanitizer.name(state.name, fallback: "Mac")
        return ListRowModel(
            title: isThisMac ? name + " (This Mac)" : name,
            trailingText: dates.mailStyle(state.publishedAt),
            line2: agents.isEmpty ? "No agents detected" : agents.joined(separator: ", "),
            line3: DeploymentsPresentation.machineDeploySummary(
                everyProject: userWide,
                oneProject: projectOnly
            )
        )
    }

    static func machineMatchesSearch(_ state: MachineState, query: String) -> Bool {
        PublishedStringSanitizer.name(state.name, fallback: "Mac")
            .localizedCaseInsensitiveContains(query)
    }

    /// "1 skill" / "3 skills" / "0 skills": the trailing counts read as counts, never as "No skills"
    /// (that placeholder belongs to the lines, where it replaces a list of names).
    static func counted(_ count: Int, _ singular: String) -> String {
        count == 1 ? "1 " + singular : "\(count) " + singular + "s"
    }

    static func abbreviatePath(_ path: String, homeDirectory: String) -> String {
        HomePath.displayAbbreviation(path, homeDirectory: homeDirectory) ?? path
    }

    static func identityLine(_ project: Project) -> String {
        switch ProjectIdentity.Kind(rawValue: project.identityKind ?? "") {
        case .remote: project.identityKey ?? "Git remote identity"
        case .marker: "Local marker identity"
        case nil: "Identity pending"
        }
    }

    /// Slugs resolve to skill names where a local row exists; an unresolved slug is shown as-is so a
    /// skill that lives only on another Mac is still visible in the count and the line.
    private static func skillNamesLine(_ slugs: [String], skills: [Skill]) -> String {
        guard !slugs.isEmpty else { return "No skills" }
        let names = slugs.map { slug in skills.first { $0.directoryName == slug }?.name ?? slug }
        return joined(names)
    }

    private static func joined(_ names: [String]) -> String {
        names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: ", ")
    }
}

/// The subtitle under a list's title: Mail's "114 messages, 92 unread" slot.
enum ListSubtitle {
    /// "No skills" when the section is empty, "4 skills" when everything is shown, "2 of 4 skills"
    /// when a search or filter narrows the list.
    static func text(total: Int, shown: Int, singular: String, plural: String) -> String {
        if total == 0 { return "No " + plural }
        let noun = total == 1 ? singular : plural
        return shown < total ? "\(shown) of \(total) " + noun : "\(total) " + noun
    }

    static func nouns(for section: SidebarSection) -> (singular: String, plural: String) {
        switch section {
        case .skills: ("skill", "skills")
        case .projects: ("project", "projects")
        case .categories: ("category", "categories")
        case .tags: ("tag", "tags")
        case .machines: ("machine", "machines")
        }
    }
}

/// Mail's date column for the narrow list: a time today, "Yesterday", otherwise the short date. One
/// value per render — a list body builds it once (two formatters) and hands it to every row builder,
/// never one formatter per row. `now` is sampled when the body runs, so an idle window's "Yesterday"
/// rolls over on its next render rather than at midnight: a declared tolerance.
struct ListDates {
    let now: Date
    let calendar: Calendar
    private let timeFormatter: DateFormatter
    private let dateFormatter: DateFormatter

    init(now: Date, calendar: Calendar = .current, locale: Locale = .current) {
        self.now = now
        self.calendar = calendar
        timeFormatter = Self.formatter(dateStyle: .none, timeStyle: .short, calendar: calendar, locale: locale)
        dateFormatter = Self.formatter(dateStyle: .short, timeStyle: .none, calendar: calendar, locale: locale)
    }

    func mailStyle(_ date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return timeFormatter.string(from: date)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return dateFormatter.string(from: date)
    }

    private static func formatter(dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style,
                                  calendar: Calendar, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter
    }
}

/// The View menu's two toggles are named by what the line shows, not by its number.
enum ListLineTitles {
    static func titles(for section: SidebarSection) -> (line2: String, line3: String?) {
        switch section {
        case .skills: ("Show Deployments", "Show Description")
        case .projects: ("Show Path", "Show Identity")
        case .categories: ("Show Projects", "Show Skills")
        case .tags: ("Show Skills", nil)
        case .machines: ("Show Agents", "Show Deployments")
        }
    }
}
