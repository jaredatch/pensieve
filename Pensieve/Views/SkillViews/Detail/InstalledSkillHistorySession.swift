import Foundation
import Observation

@MainActor
@Observable
final class InstalledSkillHistorySession {
    struct UpstreamDiff: Identifiable {
        let sha: String
        let text: String
        var id: String { sha }
    }

    struct LocalEditsDiff: Identifiable {
        let changes: [UpstreamHistoryLocalChange]
        let title: String
        let summary: String?
        var id: String { title }
    }

    var showAllReadRows = false
    var requestedWindow = 1
    var diff: UpstreamDiff?
    var edits: LocalEditsDiff?
    private(set) var mountedSkillID: UUID?

    func prepare(for skillID: UUID) -> Int {
        if mountedSkillID != skillID { reset(for: skillID) }
        return requestedWindow
    }

    func reset(for skillID: UUID) {
        mountedSkillID = skillID
        showAllReadRows = false
        requestedWindow = 1
        diff = nil
        edits = nil
    }

    func presentDiff(_ row: InstalledSkillHistoryPresentation.UpstreamRow) {
        guard let text = InstalledSkillHistoryPresentation.text(row.history.skillMarkdown) else { return }
        diff = UpstreamDiff(
            sha: row.history.sha,
            text: SkillHistoryPresentation.previewBody(from: text)
        )
    }

    func presentEdits(_ row: InstalledSkillHistoryPresentation.LocalRow) {
        edits = LocalEditsDiff(changes: row.changes, title: row.title, summary: row.detail)
    }

    func showOlder(
        _ action: InstalledSkillHistoryPresentation.OlderAction,
        currentWindow: Int
    ) {
        switch action {
        case .revealReadRows:
            showAllReadRows = true
        case .readNextWindow:
            let (next, overflow) = currentWindow.addingReportingOverflow(1)
            if !overflow { requestedWindow = next }
        }
    }
}
