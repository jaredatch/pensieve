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
    /// A failed row snapshot skips held creates; preserved peers stay registered and the file stays untouched.
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
        guard !record.held.isEmpty || !record.preserved.isEmpty || !record.retirements.isEmpty else { return }
        let durable = probeLibraryForRecordRestore()
        let state = StoreIngestState.shared(for: context.container)
        for slug in record.preserved where durable.map({ $0.skills.contains { $0.slug == slug } }) ?? true {
            preservedPeerSlugs.insert(slug)
            state.preservePeer(slug)
        }
        restoreRetirements(record.retirements, durable: durable, context: context)
        let local: ManifestSnapshot
        do { local = try manifest.snapshot(from: context) } catch {
            log("Couldn't restore refused creates: " + error.localizedDescription)
            return
        }
        restoreHeldCreates(record.held, local: local, durable: durable, context: context)
        persistRefusedCreates()
    }

    /// A daemon may be replacing overlays. Contention is an unreadable probe, never evidence
    /// that a peer's slug disappeared. Release before AppRuntime's launch job takes the same lock.
    private func probeLibraryForRecordRestore() -> ManifestSnapshot? {
        guard let lock = SyncLock.tryAcquire(at: lockPath) else { return nil }
        defer { lock.release() }
        do { return try manifest.read(fromRoot: root) } catch {
            log("Couldn't probe refused creates against the library: " + error.localizedDescription)
            return nil
        }
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

    private func restoreRetirements(_ records: [RefusedCreateRecords.Retirement], durable: ManifestSnapshot?,
                                    context: ModelContext) {
        for record in records {
            guard retirementFolderMayExist(record.slug) else { continue }
            let edit = ManifestRefusedEdit(retirement: record, context: context)
            if let durable, !edit.acknowledge(durable: durable) { continue }
            edit.retain()
            refused.append(edit)
        }
    }

    private func retirementFolderMayExist(_ slug: String) -> Bool {
        guard let folder = SkillStore.safeSkillDirectory(slug: slug, base: root + "/skills", fileService: files) else {
            return true // An unsafe or unreadable folder is not evidence of a completed deletion.
        }
        do { return try files.entryTypeWithoutFollowingLinks(at: folder) == .directory } catch { return true }
    }

    /// Mirror collision-held creates, renamed pending creates and peers kept after rename/delete.
    /// A renamed create also stays here after an ordinary write failure, carrying its intent move.
    /// Refused per-field retirements persist while their folders remain. Other refused creates are omitted.
    /// Previously recorded creates stay until acknowledgement, even when their slug is temporarily absent on disk.
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
        let retirements = refused.compactMap { edit -> RefusedCreateRecords.Retirement? in
            guard let record = edit.retirementRecord(), retirementFolderMayExist(record.slug) else {
                return nil
            }
            return record
        }
        do {
            try RefusedCreateRecords(path: refusedCreatesPath, files: files)
                .write(.init(held: held, preserved: preservedPeerSlugs.sorted(), retirements: retirements))
        } catch {
            if case RefusedCreateRecords.ReadError.unsupportedSchema = error { recordsRequireNewerVersion = true }
            log("Couldn't write refused creates at \(refusedCreatesPath): \(error)")
        }
    }
}
