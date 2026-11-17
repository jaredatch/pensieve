import Foundation
import SwiftData

extension ManifestSaveModel {
    static let renameHoldMessage = "Its changes stay on this Mac until you rename it."

    func isRefusedRename(_ item: Item, durable: ManifestSnapshot?, error: Error) -> Bool {
        if case ManifestSaveError.renameTaken = error { return true }
        return durable.map { item.change.refusedRename(in: $0) != nil } ?? false
    }

    func hasHeldRename(_ slug: String, context: ModelContext) -> Bool {
        StoreIngestState.shared(for: context.container).heldRename(slug) != nil
    }

    func heldEditSlug(_ change: ManifestChange) -> String? {
        switch change {
        case .skillMetadata(let slug, _, _), .categorySkill(_, let slug, _),
             .retireSkill(let slug), .deleteSkill(let slug): return slug
        default: return nil
        }
    }

    func applyHeldRenameDeletion(_ item: Item, to snapshot: inout ManifestSnapshot) throws -> Bool {
        guard let slug = heldEditSlug(item.change),
              let hold = StoreIngestState.shared(for: item.presentation.context.container).heldRename(slug) else { return false }
        switch item.change {
        case .retireSkill: hold.record.retire(in: &snapshot, deleting: false)
        case .deleteSkill: hold.record.retire(in: &snapshot, deleting: true)
        default: throw ManifestSaveError.createCollision(slug)
        }
        return true
    }

    func holdRefusedRename(_ item: Item) {
        guard case .renameSkill(let old, let new, let details) = item.change, let details else { return }
        let record = RefusedCreateRecords.Rename(old: old, new: new,
            createdAt: RefusedCreateRecords.writtenDate(details.original.createdAt))
        let context = item.presentation.context
        let local = try? manifest.snapshot(from: context)
        var cached = local?.skills.first { $0.slug == new && record.owns($0) } ?? details.original
        cached.slug = new
        var hold = StoreIngestState.RenameHold(record: record, cached: cached)
        for pending in items where pending.order > item.order && pending.presentation.context === context {
            hold.observe(pending.change)
        }
        StoreIngestState.shared(for: context.container).holdRename(record, cached: hold.cached)
        heldRenames.removeAll { $0.context === context && $0.record.new == new }
        heldRenames.append((record, context))
        persistRefusedCreates(excludingPublished: item.id)
    }

    /// Metadata is already on the row. Do not retain a slug-only edit that could later reach a peer.
    func retainHeldRenameEdit(_ item: Item) -> Bool {
        guard case .skillMetadata(let slug, _, _) = item.change,
              hasHeldRename(slug, context: item.presentation.context) else { return false }
        persistRefusedCreates()
        return true
    }

    func registerRestoredRenames(_ records: [RefusedCreateRecords.Rename], context: ModelContext) {
        for record in records {
            heldRenames.append((record, context))
            StoreIngestState.shared(for: context.container).holdRename(record)
        }
    }

    /// A failed read is no evidence that a held creation disappeared. Register names first.
    func validateRestoredRenames(local: ManifestSnapshot, context: ModelContext) {
        heldRenames.removeAll { hold in
            guard hold.context === context else { return false }
            let state = StoreIngestState.shared(for: context.container)
            guard let row = local.skills.first(where: { $0.slug == hold.record.new }), hold.record.owns(row) else {
                state.forgetRename(hold.record.new)
                return true
            }
            state.holdRename(hold.record, cached: row)
            return false
        }
    }

    func refreshRenameHolds(durable: ManifestSnapshot) {
        heldRenames.removeAll { hold in
            let complete = durable.skills.contains { $0.slug == hold.record.new && hold.record.owns($0) }
                && !durable.skills.contains { $0.slug == hold.record.old && hold.record.owns($0) }
            if complete {
                let state = StoreIngestState.shared(for: hold.context.container)
                if durable.skills.contains(where: { $0.slug == hold.record.old && !hold.record.owns($0) }) {
                    state.preservePeer(hold.record.old)
                    preservedPeerSlugs.insert(hold.record.old)
                }
                state.forgetRename(hold.record.new)
            }
            return complete
        }
    }

    func renameRecords(excludingPublished: UUID?) -> [RefusedCreateRecords.Rename] {
        let held = heldRenames.filter {
            StoreIngestState.shared(for: $0.context.container).heldRename($0.record.new) != nil
        }.map(\.record)
        let queued = items.compactMap { item -> RefusedCreateRecords.Rename? in
            guard item.id != excludingPublished, !item.wasHealed, !item.wasCancelled,
                  case .renameSkill(let old, let new, let details) = item.change, let details else { return nil }
            return .init(old: old, new: new, createdAt: RefusedCreateRecords.writtenDate(details.original.createdAt))
        }
        return Dictionary((queued + held).map { ($0.new, $0) }, uniquingKeysWith: { _, last in last })
            .values.sorted { $0.new < $1.new }
    }

    /// A quit after local deletion must replay against the owned source, never the peer's slug.
    func heldRenameDeletionRecord(_ deletion: RefusedCreateRecords.Deletion, context: ModelContext)
        -> RefusedCreateRecords.Deletion? {
        let state = StoreIngestState.shared(for: context.container)
        guard let hold = state.heldRename(deletion.slug) else { return nil }
        for name in [hold.record.old, hold.record.new] {
            state.preservePeer(name)
            preservedPeerSlugs.insert(name)
        }
        return .init(slug: hold.record.old, machineID: nil, createdAt: hold.record.createdAt, requiresCreation: true)
    }

    func finishHeldRenamePublication(_ item: Item, durable: ManifestSnapshot) {
        guard case .deleteSkill(let slug) = item.change, hasHeldRename(slug, context: item.presentation.context) else { return }
        releaseRenameHold(slug, context: item.presentation.context, durable: durable)
    }

    func releaseRenameHold(_ slug: String, context: ModelContext, durable: ManifestSnapshot?) {
        let state = StoreIngestState.shared(for: context.container)
        guard let hold = state.heldRename(slug) else { return }
        state.preservePeer(slug)
        preservedPeerSlugs.insert(slug)
        if durable?.skills.contains(where: { $0.slug == hold.record.old && !hold.record.owns($0) }) == true {
            state.preservePeer(hold.record.old)
            preservedPeerSlugs.insert(hold.record.old)
        }
        state.forgetRename(slug)
        heldRenames.removeAll { $0.context === context && $0.record.new == slug }
    }
}
