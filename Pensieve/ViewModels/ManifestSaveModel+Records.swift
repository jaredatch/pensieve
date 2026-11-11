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
        guard !record.held.isEmpty || !record.preserved.isEmpty
            || !record.retirements.isEmpty || !record.deletions.isEmpty else { return }
        let durable = probeLibraryForRecordRestore()
        let state = StoreIngestState.shared(for: context.container)
        for slug in record.preserved where durable.map({ $0.skills.contains { $0.slug == slug } }) ?? true {
            preservedPeerSlugs.insert(slug)
            state.preservePeer(slug)
        }
        restoreRetirements(record.retirements, durable: durable, context: context)
        restoreDeletions(record.deletions, context: context)
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

    private func restoreDeletions(_ records: [RefusedCreateRecords.Deletion], context: ModelContext) {
        for record in records where !retirementFolderMayExist(record.slug) {
            let changes: [ManifestChange] = record.machineID.map { [.retireLocalSkill(record.slug, $0)] }
                ?? [.retireSkill(record.slug), .deleteSkill(record.slug)]
            let edits = changes.map { ManifestRefusedEdit($0, context: context, order: -1) }
            for edit in edits {
                edit.retain()
                refused.append(edit)
            }
            restoredDeletions.append(.init(slug: record.slug, changes: changes, projectionIDs: Set(edits.map(\.id))))
        }
    }

    /// A helper can pull a new creation while launch rebuilds. Withdraw both the replay and
    /// its projections; the caller must rebuild again before exposing or publishing those rows.
    func discardReappearedRestoredDeletions() -> Bool {
        let reappeared = restoredDeletions.filter { retirementFolderMayExist($0.slug) }
        guard !reappeared.isEmpty else { return false }
        let slugs = Set(reappeared.map(\.slug))
        let projectionIDs = Set(reappeared.flatMap(\.projectionIDs))
        restoredDeletions.removeAll { slugs.contains($0.slug) }
        refused.removeAll { projectionIDs.contains($0.id) }
        persistRefusedCreates()
        return true
    }

    /// Launch owns sync.lock while rebuilding. Replay only after its verdict, with projections
    /// already registered so no stale membership or request reaches the window in between.
    func replayRestoredDeletions(context: ModelContext) {
        let changes = restoredDeletions.flatMap(\.changes)
        restoredDeletions = []
        for change in changes { submit(change, context: context) { _ in } }
    }

    private func retirementFolderMayExist(_ slug: String) -> Bool {
        guard let folder = SkillStore.safeSkillDirectory(slug: slug, base: root + "/skills", fileService: files) else {
            return true // An unsafe or unreadable folder is not evidence of a completed deletion.
        }
        do { return try files.entryTypeWithoutFollowingLinks(at: folder) == .directory } catch { return true }
    }

    /// Mirror collision-held creates, renamed pending creates and peers kept after rename/delete.
    /// A renamed create also stays here after an ordinary write failure, carrying its intent move.
    /// Retire/delete edits persist before folder removal; refused per-field retirements also keep their fields.
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
        let deletions = deletionRecords(excludingPublished: excludingPublished)
        do {
            try RefusedCreateRecords(path: refusedCreatesPath, files: files)
                .write(.init(held: held, preserved: preservedPeerSlugs.sorted(), retirements: retirements, deletions: deletions))
        } catch {
            if case RefusedCreateRecords.ReadError.unsupportedSchema = error { recordsRequireNewerVersion = true }
            log("Couldn't write refused creates at \(refusedCreatesPath): \(error)")
        }
    }

    private func deletionRecords(excludingPublished: UUID?) -> [RefusedCreateRecords.Deletion] {
        let pending = items.filter { $0.id != excludingPublished && !$0.wasHealed }.map(\.presentation)
        let records = (refused + pending).compactMap { edit -> RefusedCreateRecords.Deletion? in
            guard let record = edit.deletionRecord else { return nil }
            let localOnly = record.machineID != nil
            let peer = edit.deletesSkillOverlay
                && (hasCollision(record.slug, context: edit.context) || preservedPeerSlugs.contains(record.slug))
            if localOnly || peer {
                // A failed row save never queues deleteSkill. Protect its peer at retirement too.
                preservedPeerSlugs.insert(record.slug)
                StoreIngestState.shared(for: edit.context.container).preservePeer(record.slug)
                if !localOnly { return nil }
            }
            return record
        }
        return Dictionary(records.map { ($0.slug, $0) }, uniquingKeysWith: { first, last in
            first.machineID == nil ? first : last
        }).values.sorted { $0.slug < $1.slug }
    }
}
