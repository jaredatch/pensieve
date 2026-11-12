import Foundation
import SwiftData

extension ManifestSaveModel {
    @MainActor
    func waitUntilIdle() async {
        while let worker { await worker.value }
    }

    func hasPendingRename(_ slug: String, context: ModelContext) -> Bool {
        items.contains {
            guard $0.presentation.context === context, case .renameSkill(_, let new, _) = $0.change else { return false }
            return new == slug
        }
    }

    /// The caller still owns sync.lock. Refused renames never become retained create projections.
    @MainActor
    func restoreRefusedRename(_ item: Item, durable: ManifestSnapshot?, error: Error) -> Error {
        guard case .renameSkill(let old, let new, let details) = item.change,
              let undo = details?.undo, let durable else { return error }
        do {
            let following = items.filter { $0.order > item.order && $0.presentation.context === item.presentation.context }
                .map { $0.change.retargetingSkill(from: new, to: old) }
            let notice = try undo.restore(durable: durable, following: following, context: item.presentation.context)
            retargetPendingSkills(after: item, from: new, to: old)
            if let notice { return ManifestSaveError.renameRestoreFailed(error.localizedDescription + " " + notice) }
            return error
        } catch {
            return ManifestSaveError.renameRestoreFailed(errorMessage(error, new: new))
        }
    }

    @discardableResult
    func keepPendingRenameLocal(_ item: Item, in snapshot: inout ManifestSnapshot) -> Bool {
        guard case .renameSkill(_, let new, let details) = item.change, let details,
              let local = try? item.fallback().skills.first(where: { $0.slug == new }),
              ManifestService.sameCreation(local, details.original) else { return false }
        snapshot.skills.removeAll { $0.slug == new }
        snapshot.skills.append(local)
        return true
    }

    private func errorMessage(_ error: Error, new: String) -> String {
        ManifestSaveError.renameTaken(new).localizedDescription
            + " The folder is still under “\(new)” because \(error.localizedDescription)"
    }

    private func retargetPendingSkills(after item: Item, from old: String, to new: String) {
        let context = item.presentation.context
        var ids: Set<UUID> = []
        for index in items.indices where items[index].order > item.order && items[index].presentation.context === context {
            items[index].change = items[index].change.retargetingSkill(from: old, to: new)
            items[index].categoryEdit?.retargetSkill(from: old, to: new)
            items[index].presentation.retargetSkill(from: old, to: new)
            ids.insert(items[index].id)
        }
        StoreIngestState.shared(for: context.container).retargetSkill(from: old, to: new, ids: ids)
        // Older held edits keep their owed targets. Only their cached window observed
        // the forward rename, so reverse that observation without changing original or fields.
        for edit in refused where edit.context === context {
            edit.observe(.renameSkill(old, new))
        }
    }
}
