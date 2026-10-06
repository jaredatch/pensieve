import Foundation

/// Pure copy and action policy for an installed skill's upstream timeline. Remote strings remain values
/// for inert `Text` rendering; this type never turns them into markup.
enum InstalledSkillHistoryPresentation {
    enum Content: Equatable {
        case loading
        case failed(message: String, installedSummary: String)
        case loaded(UpstreamHistoryResult, isUpdating: Bool, failureMessage: String?)
    }

    struct RequestID: Hashable {
        let skillID: UUID
        let originData: Data?
        let recordedHead: String?
        let localRevision: UpstreamHistoryLocalRevision
        let windowCount: Int
        let manualCheckCount: UInt64

        init(
            skill: Skill,
            localRevision: UpstreamHistoryLocalRevision,
            windowCount: Int,
            manualCheckCount: UInt64 = 0
        ) {
            skillID = skill.id
            originData = skill.installedOriginData
            recordedHead = skill.lastCheckedHead
            self.localRevision = localRevision
            self.windowCount = windowCount
            self.manualCheckCount = manualCheckCount
        }
    }

    enum Badge: Equatable {
        case available
        case installed
    }

    enum OlderAction: Equatable {
        case revealReadRows
        case readNextWindow
    }

    struct UpstreamRow: Equatable, Identifiable {
        let history: UpstreamHistoryRow
        let shortHash: String
        let date: String
        let filesText: String
        let additionsText: String?
        let deletionsText: String?
        let badge: Badge?
        let canViewDiff: Bool
        let canUpdate: Bool
        var id: String { history.sha }
        var stats: String {
            ChangeStatsParts(leadingText: filesText, additions: additionsText, deletions: deletionsText).joined
        }
    }

    struct LocalRow: Equatable {
        let title: String
        let detailText: String?
        let additionsText: String?
        let deletionsText: String?
        let changes: [UpstreamHistoryLocalChange]
        let canViewEdits: Bool
        var detail: String? {
            detailText.map { ChangeStatsParts(leadingText: $0, additions: additionsText, deletions: deletionsText).joined }
        }
    }

    private struct ChangeStatsParts {
        let leadingText: String
        let additions: String?
        let deletions: String?
        /// The one-string form the accessibility labels and the older callers read.
        var joined: String {
            guard let additions, let deletions else { return leadingText }
            return leadingText + " · \(additions) \(deletions)"
        }
    }

    static let initiallyShown = 10
    static let loadingTitle = "Loading upstream history…"
    static let updatingTitle = "Updating…"
    static let localCaption = "Your local edits · not yet saved to a version"
    static let showOlderTitle = "Show older commits"
    static let tryAgainTitle = "Try Again"
    static let viewDiffTitle = "View Diff"
    static let viewEditsTitle = "View Edits"
    static let updateTitle = "Update to This"

    static func shortHash(_ sha: String) -> String {
        String(sha.prefix(7))
    }

    static func content(
        state: UpstreamHistoryLoadState,
        currentSkillID: UUID?,
        skillID: UUID,
        origin: InstalledOrigin
    ) -> Content {
        guard currentSkillID == skillID else { return .loading }
        switch state {
        case .idle, .loading:
            return .loading
        case let .refreshing(result):
            return .loaded(result, isUpdating: true, failureMessage: nil)
        case let .failed(message):
            return .failed(message: message, installedSummary: installedSummary(origin: origin))
        case let .loaded(result):
            return .loaded(result, isUpdating: false, failureMessage: nil)
        case let .loadedWithFailure(result, message):
            return .loaded(result, isUpdating: false, failureMessage: message)
        }
    }

    static func date(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day().locale(locale)
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(style)
        }
        return date.formatted(style.year())
    }

    static func stats(files: Int, added: Int?, removed: Int?) -> String {
        statsComponents(files: files, added: added, removed: removed).joined
    }

    static func upstreamRows(
        result: UpstreamHistoryResult,
        shownCount: Int,
        updateAvailable: Bool,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [UpstreamRow] {
        let rows = Array(result.rows.prefix(shownCount))
        return rows.enumerated().map { index, row in
            let badge = badge(for: row.sha, position: result.installedPosition, rows: result.rows)
            let components = statsComponents(
                files: row.filesChanged,
                added: row.linesAdded,
                removed: row.linesRemoved
            )
            return UpstreamRow(
                history: row,
                shortHash: shortHash(row.sha),
                date: date(row.date, now: now, calendar: calendar, locale: locale),
                filesText: components.leadingText,
                additionsText: components.additions,
                deletionsText: components.deletions,
                badge: badge,
                canViewDiff: badge != .installed && text(row.skillMarkdown) != nil,
                canUpdate: updateAvailable && index == 0 && badge == .available
            )
        }
    }

    static func localRow(
        edits: UpstreamHistoryLocalEdits,
        baseline: UpstreamHistoryBaseline?,
        installedCommit: String
    ) -> LocalRow? {
        switch edits {
        case .none:
            return nil
        case .countsUnknown:
            return LocalRow(
                title: "This copy has local edits",
                detailText: nil,
                additionsText: nil,
                deletionsText: nil,
                changes: [],
                canViewEdits: false
            )
        case let .changed(changes):
            let count = changes.count
            let noun = count == 1 ? "file" : "files"
            let title = "\(count) \(noun) changed since you installed \(shortHash(installedCommit))"
            let components = localDetailComponents(changes)
            return LocalRow(
                title: title,
                detailText: components?.leadingText,
                additionsText: components?.additions,
                deletionsText: components?.deletions,
                changes: changes,
                canViewEdits: baseline?.files != nil
            )
        }
    }

    static func olderAction(total: Int, shown: Int, hasOlderHistory: Bool) -> OlderAction? {
        if shown < total { return .revealReadRows }
        return hasOlderHistory ? .readNextWindow : nil
    }

    static func text(_ content: UpstreamHistoryText?) -> String? {
        guard case let .text(text) = content else { return nil }
        return text
    }

    static func installedNote(position: UpstreamHistoryInstalledPosition, commit: String, ref: String) -> String? {
        guard position == .notInRefHistory else { return nil }
        return "Installed version \(shortHash(commit)) is no longer in \(ref)."
    }

    static func installedSummary(origin: InstalledOrigin) -> String {
        "Installed \(shortHash(origin.installedCommit)) · \(date(origin.installedAt))"
    }
}

private extension InstalledSkillHistoryPresentation {
    private static func statsComponents(
        files: Int,
        added: Int?,
        removed: Int?
    ) -> ChangeStatsParts {
        let noun = files == 1 ? "file" : "files"
        let filesText = "\(files) \(noun) changed"
        guard let added, let removed else {
            return ChangeStatsParts(leadingText: filesText, additions: nil, deletions: nil)
        }
        return ChangeStatsParts(leadingText: filesText, additions: "+\(added)", deletions: "−\(removed)")
    }

    static func badge(
        for sha: String,
        position: UpstreamHistoryInstalledPosition,
        rows: [UpstreamHistoryRow]
    ) -> Badge? {
        switch position {
        case let .at(installedSHA):
            if sha == installedSHA { return .installed }
            guard let installedIndex = rows.firstIndex(where: { $0.sha == installedSHA }),
                  let rowIndex = rows.firstIndex(where: { $0.sha == sha }) else { return nil }
            return rowIndex < installedIndex ? .available : nil
        case .olderThanRowsRead, .notInRefHistory:
            return .available
        }
    }

    static func localDetail(_ changes: [UpstreamHistoryLocalChange]) -> String? {
        localDetailComponents(changes)?.joined
    }

    private static func localDetailComponents(
        _ changes: [UpstreamHistoryLocalChange]
    ) -> ChangeStatsParts? {
        guard !changes.isEmpty else { return nil }
        var parts = Array(changes.prefix(2).map(\.path))
        if changes.count > 2 { parts.append("and \(changes.count - 2) more") }
        let detail = parts.joined(separator: ", ")
        guard changes.allSatisfy({ $0.linesAdded != nil && $0.linesRemoved != nil }) else {
            return ChangeStatsParts(leadingText: detail, additions: nil, deletions: nil)
        }
        let added = changes.compactMap(\.linesAdded).reduce(0, +)
        let removed = changes.compactMap(\.linesRemoved).reduce(0, +)
        return ChangeStatsParts(leadingText: detail, additions: "+\(added)", deletions: "−\(removed)")
    }
}
