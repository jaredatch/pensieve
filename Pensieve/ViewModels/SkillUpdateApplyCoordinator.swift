import Foundation
import SwiftData

@MainActor
protocol SkillUpdateApplyObserving: AnyObject {
    func applyFinished(row: UpdatesRow, status: UpdatesRowStatus?, context: ModelContext)
}

/// Delivers completion to currently open surfaces; no outcome survives in this process-owned object.
@MainActor
final class SkillUpdateApplyCoordinator {
    let gate = SkillUpdateApplyGate()
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
        gate.begin(id)
    }

    func finish(row: UpdatesRow, status: UpdatesRowStatus?, context: ModelContext) {
        gate.end(row.id)
        observers.forEach { $0.value?.applyFinished(row: row, status: status,
                                                   context: context) }
    }
}

extension UpdatesRow {
    // A re-check can move the upstream pin. The apply still consumes every row based on the replaced install.
    func hasSameInstalledCommit(as other: UpdatesRow) -> Bool {
        id == other.id && installedCommit == other.installedCommit
    }
}
