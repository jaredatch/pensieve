import Foundation
import SwiftData

extension ManifestSaveModel {
    func hasRefusedCreate(_ slug: String, context: ModelContext) -> Bool {
        refused.contains { $0.context === context && $0.createdSkill?.slug == slug }
    }

    func hasCollision(_ slug: String, context: ModelContext) -> Bool {
        refused.contains { $0.context === context && $0.createdSkill?.slug == slug && $0.isCollisionHeld }
    }

    func discardRefusedCreate(_ slug: String, context: ModelContext) {
        let state = StoreIngestState.shared(for: context.container)
        for edit in refused where edit.context === context && edit.createdSkill?.slug == slug {
            if edit.isCollisionHeld, let slug = edit.createdSkill?.slug {
                state.preservePeer(slug)
                preservedPeerSlugs.insert(slug)
            }
        }
        refused.removeAll { $0.context === context && $0.targets(slug) }
        persistRefusedCreates()
    }

    /// Register projections on the window's container before any worker rebuild can replace its rows.
    /// One failed row snapshot leaves the complete file untouched, including preserved peers.
    @MainActor
    func restoreRefusedCreates(context: ModelContext) {
        guard let refusedCreatesPath else { return }
        let store = RefusedCreateRecords(path: refusedCreatesPath, files: files)
        let record: RefusedCreateRecords.Record
        do { record = try store.read() } catch {
            if case RefusedCreateRecords.ReadError.unsupportedSchema = error { recordsRequireNewerVersion = true }
            log("Couldn't read refused creates at \(refusedCreatesPath): \(error)")
            return
        }
        guard !record.held.isEmpty || !record.preserved.isEmpty else { return }
        let local: ManifestSnapshot
        do { local = try manifest.snapshot(from: context) } catch {
            log("Couldn't restore refused creates: " + error.localizedDescription)
            return
        }
        let durable: ManifestSnapshot?
        do { durable = try manifest.read(fromRoot: root) } catch {
            durable = nil
            log("Couldn't probe refused creates against the library: " + error.localizedDescription)
        }
        let state = StoreIngestState.shared(for: context.container)
        for slug in record.preserved where durable.map({ $0.skills.contains { $0.slug == slug } }) ?? true {
            preservedPeerSlugs.insert(slug)
            state.preservePeer(slug)
        }
        restoreHeldCreates(record.held, local: local, durable: durable, context: context)
        persistRefusedCreates()
    }

    private func restoreHeldCreates(_ held: [RefusedCreateRecords.Held], local: ManifestSnapshot,
                                    durable: ManifestSnapshot?, context: ModelContext) {
        for held in held {
            guard let row = local.skills.first(where: { $0.slug == held.slug }),
                  RefusedCreateRecords.writtenDate(row.createdAt) == held.createdAt else { continue }
            let edit = ManifestRefusedEdit(.createSkill(row), context: context, intentMove: held.intentMove)
            edit.cache(local: local)
            if let durable {
                guard edit.acknowledge(durable: durable) else { continue }
            } else { edit.holdUntilReadableProbe() }
            edit.retain()
            refused.append(edit)
            recordedCreateSlugs.insert(held.slug)
        }
    }

    /// Mirror collision-held creates, renamed pending creates and peers kept after rename/delete.
    /// Ordinary refused creates never enter this file. Previously recorded creates stay until an
    /// acknowledgement even when a readable probe finds their slug temporarily absent on disk.
    func persistRefusedCreates(excludingPublished: UUID? = nil) {
        guard let refusedCreatesPath, !recordsRequireNewerVersion else { return }
        let retained = refused.compactMap { edit -> RefusedCreateRecords.Held? in
            guard let create = edit.createdSkill,
                  edit.isCollisionHeld || edit.intentMove != nil || recordedCreateSlugs.contains(create.slug) else { return nil }
            return .init(slug: create.slug, createdAt: RefusedCreateRecords.writtenDate(create.createdAt),
                         intentMove: edit.intentMove)
        }
        // Rename has already saved its moved row. Persist the intent move before its async queue
        // runs too, so quitting here cannot strand the durable intent under the previous name.
        let queued = items.compactMap { item -> RefusedCreateRecords.Held? in
            guard item.id != excludingPublished, !item.wasHealed, let move = item.intentMove,
                  let create = item.presentation.createdSkill else { return nil }
            return .init(slug: create.slug, createdAt: RefusedCreateRecords.writtenDate(create.createdAt), intentMove: move)
        }
        let held = Dictionary((retained + queued).map { ($0.slug, $0) }, uniquingKeysWith: { _, last in last })
            .values.sorted { $0.slug < $1.slug }
        recordedCreateSlugs = Set(held.map(\.slug))
        do {
            try RefusedCreateRecords(path: refusedCreatesPath, files: files)
                .write(.init(held: held, preserved: preservedPeerSlugs.sorted()))
        } catch {
            if case RefusedCreateRecords.ReadError.unsupportedSchema = error { recordsRequireNewerVersion = true }
            log("Couldn't write refused creates at \(refusedCreatesPath): \(error)")
        }
    }
}
