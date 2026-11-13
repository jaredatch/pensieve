import Foundation

/// Text already read by History, stamped with the revision under which its current side was read.
/// No file reads or repository operations belong to the comparison window's History input.
struct HistoryDiffComparison: Equatable {
    let skillID: UUID
    let skillName: String
    let sourceID: String
    let subtitle: String
    let revision: UpstreamHistoryLocalRevision?
    let changes: [FileTreeChange]

    static func body(skill: Skill, sourceID: String, subtitle: String, old: String, current: String,
                     revision: UpstreamHistoryLocalRevision) -> Self {
        Self(skillID: skill.id, skillName: skill.name, sourceID: sourceID, subtitle: subtitle, revision: revision,
             changes: textChanges([UpstreamHistoryLocalChange(path: "SKILL.md", linesAdded: nil, linesRemoved: nil,
                 installedText: old, currentText: current)]))
    }

    static func edits(skill: Skill, changes: [UpstreamHistoryLocalChange],
                      revision: UpstreamHistoryLocalRevision?) -> Self {
        Self(skillID: skill.id, skillName: skill.name, sourceID: "edits", subtitle: "Installed → This copy",
             revision: revision, changes: textChanges(changes))
    }

    private static func textChanges(_ changes: [UpstreamHistoryLocalChange]) -> [FileTreeChange] {
        changes.compactMap { change in
            guard change.installedText != nil || change.currentText != nil else { return nil }
            let old = change.installedText ?? "", new = change.currentText ?? ""
            guard change.installedText == nil || change.currentText == nil
                || Data(old.utf8) != Data(new.utf8) else { return nil }
            return FileTreeChange(path: change.path,
                                  kind: change.installedText == nil ? .added : change.currentText == nil ? .removed : .modified,
                                  content: .text(old: old, new: new))
        }
    }

    func build() throws -> PinnedSkillDiff {
        try PinnedSkillDiff.build(comparison: FileTreeComparison(changes: changes, unreadFileCount: 0, bytesRead: 0))
    }
}

extension ViewChangesViewModel {
    var isHistory: Bool { historyComparison != nil }
    var heading: String { historyComparison.map { "Changes to \($0.skillName)" }
        ?? row.map { "Changes to \($0.skillName)" } ?? "View Changes" }
    var subtitle: String { historyComparison?.subtitle ?? row.map(ViewChangesPresentation.subtitle) ?? "" }
}
