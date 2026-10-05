import Foundation
import SwiftData

extension UpdatesViewModel: SkillUpdateApplyObserving {
    func applyFinished(row: UpdatesRow, status: UpdatesRowStatus?, context: ModelContext) {
        guard let status else { return }
        acceptApplyOutcome(row: row, status: status)
    }

    func acceptApplyOutcome(row: UpdatesRow, status: UpdatesRowStatus) {
        guard let index = rows.firstIndex(where: { $0.hasSameInstalledCommit(as: row) }) else { return }
        statuses[row.id] = status
        switch status {
        case .updated, .failedAfterReplacement:
            selectedSkillIDs.remove(row.id)
            confirmedDriftSkillIDs.remove(row.id)
        case .confirmationRequired:
            confirmedDriftSkillIDs.remove(row.id)
            rows[index] = rows[index].markedDrifted()
        case .idle, .updating, .failed:
            break
        }
    }

    func canSelect(_ row: UpdatesRow) -> Bool {
        guard canonicalStatus(for: row) == nil else { return false }
        switch status(for: row) {
        case .updated, .failedAfterReplacement: return false
        default: return true
        }
    }

    func canonicalStatus(for row: UpdatesRow) -> UpdatesRowStatus? {
        guard let skill = presentationSkills[row.id] else { return nil }
        guard skill.modelContext != nil, !skill.isDeleted else { return .updated }
        guard let origin = skill.installedOrigin,
              origin.installedCommit == row.upstreamCommit,
              origin.installedTree == row.upstreamTree else { return nil }
        return .updated
    }

}
