import Foundation
import SwiftData

@MainActor
protocol SkillUpdateApplyObserving: AnyObject {
    func applyReservationsChanged()
    func applyFinished(row: UpdatesRow, status: UpdatesRowStatus, context: ModelContext, folderRevisions: [String: UInt64])
}

/// Shares process outcomes with open review surfaces; the gate itself owns reservations only.
@MainActor
final class SkillUpdateApplyCoordinator {
    let gate = SkillUpdateApplyGate()
    private var outcomes: [UUID: (row: UpdatesRow, status: UpdatesRowStatus)] = [:]
    private var observers: [Observer] = []

    private final class Observer {
        weak var value: SkillUpdateApplyObserving?
        init(_ value: SkillUpdateApplyObserving) { self.value = value }
    }

    func observe(_ observer: SkillUpdateApplyObserving) {
        observers.removeAll { $0.value == nil }
        observers.append(Observer(observer))
    }

    func begin(_ id: UUID) -> Bool {
        guard gate.begin(id) else { return false }
        observers.forEach { $0.value?.applyReservationsChanged() }
        return true
    }

    func finish(row: UpdatesRow, status: UpdatesRowStatus, context: ModelContext, folderRevisions: [String: UInt64]) {
        outcomes[row.id] = (row, status)
        gate.end(row.id)
        observers.forEach { $0.value?.applyFinished(row: row, status: status,
                                                   context: context, folderRevisions: folderRevisions) }
        observers.forEach { $0.value?.applyReservationsChanged() }
    }

    func outcome(for row: UpdatesRow) -> UpdatesRowStatus? {
        guard let outcome = outcomes[row.id], outcome.row.hasSameInstalledCommit(as: row) else { return nil }
        return outcome.status
    }
}

extension UpdatesRow {
    // A re-check can move the upstream pin. The apply still consumes every row based on the replaced install.
    func hasSameInstalledCommit(as other: UpdatesRow) -> Bool {
        id == other.id && installedCommit == other.installedCommit
    }
}
