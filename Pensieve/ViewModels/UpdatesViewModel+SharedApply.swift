import Foundation
import SwiftData

extension UpdatesViewModel: SkillUpdateApplyObserving {
    func applyReservationsChanged() {
        hasReservedRows = applyGate.hasReservations(in: rowIDs)
    }

    func applyFinished(row: UpdatesRow, status: UpdatesRowStatus, context: ModelContext, folderRevisions: [String: UInt64]) {
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
        switch status(for: row) {
        case .updated, .failedAfterReplacement: return false
        default: return true
        }
    }

    func isUpdatingElsewhere(_ row: UpdatesRow) -> Bool {
        applyGate.isApplying(row.id) && statuses[row.id] != .updating
    }
}
