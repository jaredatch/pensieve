import Foundation
import Observation

/// Process-owned quit barrier for sync operations that must finish after their first write.
@MainActor
@Observable
final class SyncStepModel {
    nonisolated init() {}
    private var active: Set<UUID> = []
    var pendingCount: Int { active.count }

    func begin() -> UUID {
        let id = UUID()
        active.insert(id)
        return id
    }

    func finish(_ id: UUID) { active.remove(id) }

}
