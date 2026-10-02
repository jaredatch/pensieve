import Foundation

/// One version of `SKILL.md` in the sync repo: the commit, without its document (read on demand for View
/// Diff and Restore, one `git show` at a time).
struct SkillHistoryVersion: Equatable, Identifiable {
    let sha: String
    let date: Date
    let author: String
    let subject: String
    var id: String { sha }
}

/// The versions, read once off the render path when the History tab is shown; empty when the store has no
/// git or the file no history (`GitService.log` reads both as none — the sheet read them the same way).
struct SkillHistorySnapshot: Equatable {
    var versions: [SkillHistoryVersion] = []

    struct ReloadKey: Hashable {
        let skillID: UUID
        let reloadToken: Int
        let appWriteRevision: Int
        let syncSignal: SkillHistorySyncSignal
    }

    static let limit = 50

    static func path(for skill: Skill) -> String { "skills/\(skill.directoryName)/SKILL.md" }

    static func load(skill: Skill, git: GitServiceProtocol, workingDir: String) -> SkillHistorySnapshot {
        let commits = git.log(forPath: path(for: skill), at: workingDir, limit: limit)
        return SkillHistorySnapshot(versions: commits.map {
            SkillHistoryVersion(sha: $0.sha, date: $0.date, author: $0.author, subject: $0.subject)
        })
    }
}

/// The rows the tab draws (the frame `Skills / Details — History (authored)`): the newest is Current; the
/// connector runs from the first dot to the last; three rows show until "Show older versions".
enum SkillHistoryTimeline {
    struct Row: Equatable, Identifiable {
        let version: SkillHistoryVersion
        let isCurrent: Bool
        let connectsUp: Bool
        let connectsDown: Bool
        var id: String { version.sha }
    }

    static let initiallyShown = 3

    static func rows(_ versions: [SkillHistoryVersion], showAll: Bool) -> [Row] {
        let shown = showAll ? versions : Array(versions.prefix(initiallyShown))
        return shown.enumerated().map { index, version in
            Row(version: version, isCurrent: index == 0,
                connectsUp: index > 0, connectsDown: index < shown.count - 1)
        }
    }

    /// "Show older versions" while rows are hidden, else nil.
    static func olderLabel(total: Int, shown: Int) -> String? {
        total > shown ? "Show older versions" : nil
    }

    /// "Aug 19, 2026 at 11:38 AM · Pensieve Sync" — the date the way Finder prints one, then the author.
    static func meta(for version: SkillHistoryVersion, locale: Locale = .current) -> String {
        version.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale))
            + " · " + version.author
    }
}
