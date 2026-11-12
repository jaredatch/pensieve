import Foundation
import SwiftData

extension ManifestSaveModel {
    enum HeadEditVerdict { case ready(PreparedStoreRebuild), refused(Error) }

    struct StagedRefusal {
        let id: UUID
        let order: Int
        let complete: () -> Void
    }

    struct SaveResult {
        let published: Bool
        let error: Error?
    }

    enum Publication {
        case skipped(ManifestSnapshot)
        case saved(ManifestSnapshot)
        case headChanged
    }

    struct ManifestRead {
        let disk: ManifestSnapshot?
        let head: GitHeadStamp.State
    }

    private struct RebuildObservation {
        let value: PreparedStoreRebuild
        let before: GitHeadStamp.State
        let after: GitHeadStamp.State
        var stable: Bool { before == after }
        var ingest: StoreIngestState.Observation<PreparedStoreRebuild> {
            .init(value: value, before: before.oid, after: after.oid)
        }
    }

    var knownCreates: [SkillOverlay] {
        (refused + items.map(\.presentation)).compactMap(\.createdSkill)
    }

    @MainActor
    func publish(_ item: Item, disk: ManifestSnapshot?, head: GitHeadStamp.State) async throws
        -> Publication? {
        var saved = try disk ?? item.fallback()
        // A fallback publishes this context's whole window. Capture its queue membership before
        // awaiting the write; another context or an edit submitted during the write is not healed.
        let healedItems = disk == nil ? Set(items.filter {
            $0.presentation.context === item.presentation.context && !$0.wasCancelled
        }.map(\.id)) : []
        let context = item.presentation.context
        let collisionDelete = try collisionDeletion(for: item)
        if disk != nil, !item.wasHealed { try item.change.validate(in: saved) }
        if disk != nil, !item.wasHealed, collisionDelete == nil, !item.change.apply(to: &saved) {
            if refused.contains(where: { $0.suppliesTarget(for: item.presentation) }) {
                throw ManifestSaveError.unsavedTarget
            }
            if !item.change.isDeletion {
                log("Skipped queued manifest change: its target was removed by sync.")
                observeSavedRename(item)
                persistRefusedCreates(excludingPublished: item.id)
                return .skipped(saved)
            }
        }
        if let move = item.intentMove {
            let local = try moveWindow(for: move, context: context, snapshot: saved)
            move.apply(to: &saved, durable: disk ?? saved, local: local, knownCreates: knownCreates)
        }
        let snapshot = saved, manifest = manifest, root = root, files = files
        let headChanged = try await BlockingWork.run { () -> Bool? in
            let stamp = GitHeadStamp(fileService: files)
            guard stamp.state(root: root) == head else { return nil }
            try manifest.write(snapshot, toRoot: root)
            return stamp.state(root: root) != head
        }
        guard let headChanged else { return nil }
        let ingest = StoreIngestState.shared(for: item.presentation.context.container)
        if headChanged { ingest.invalidate() }
        finishPublishedItems(item, healedItems: healedItems, ingest: ingest)
        if let collisionDelete { discardRefusedCreate(collisionDelete, context: context) }
        acknowledgePublication(item, durable: saved)
        persistRefusedCreates(excludingPublished: item.id)
        return headChanged ? .headChanged : .saved(saved)
    }

    @MainActor
    private func finishPublishedItems(_ item: Item, healedItems: Set<UUID>, ingest: StoreIngestState) {
        ingest.finish(item.id)
        for index in items.indices where healedItems.contains(items[index].id) {
            observeSavedRename(items[index])
            items[index].wasHealed = true
            ingest.finish(items[index].id)
        }
        if !healedItems.contains(item.id) { observeSavedRename(item) }
    }

    @MainActor
    func observeSavedRename(_ item: Item) {
        // A healed item was announced with the whole-window write, exactly once.
        guard !item.wasHealed, case .renameCategory = item.change else { return }
        for edit in refused + items.map(\.presentation) where edit.context === item.presentation.context {
            edit.observeSavedRename(item.change)
        }
    }

    @MainActor
    private func acknowledgePublication(_ item: Item, durable: ManifestSnapshot) {
        for edit in refused where edit.context === item.presentation.context {
            edit.observePublished(item.change, order: item.order, durable: durable)
        }
        refused = refused.filter { $0.acknowledge(durable: durable) }
    }

    @MainActor
    private func moveWindow(for move: ManifestLocalIntentMove, context: ModelContext,
                            snapshot: ManifestSnapshot) throws -> ManifestSnapshot? {
        do { return try manifest.snapshot(from: context) } catch {
            // Refuse before writing: a missing window cannot decide which creation owns
            // the old name's memberships and requests. Retention will preserve the move.
            if move.reusesCarriedName(in: snapshot, knownCreates: knownCreates) { throw error }
            return nil
        }
    }

    private func collisionDeletion(for item: Item) throws -> String? {
        switch item.change {
        case .deleteSkill(let slug) where hasCollision(slug, context: item.presentation.context): return slug
        case .skillMetadata(let slug, _, _) where hasCollision(slug, context: item.presentation.context):
            throw ManifestSaveError.createCollision(slug)
        default: return nil
        }
    }

    @MainActor
    func readCurrentManifest() async throws -> ManifestRead {
        let manifest = manifest, root = root, files = files
        return try await BlockingWork.run {
            let head = GitHeadStamp(fileService: files).state(root: root)
            let read = try ManifestService.classifiedRead(using: manifest, root: root, files: files)
            return ManifestRead(disk: read.missing ? nil : read.snapshot, head: head)
        }
    }

    @MainActor
    func rebuild(_ item: Item, durable: ManifestSnapshot, published: Bool,
                 prepared: PreparedStoreRebuild? = nil) async -> Error? {
        do {
            if let prepared {
                var accepted = durable
                let overlays = Dictionary(durable.skills.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
                accepted.skills = prepared.snapshot.skills.map { overlays[$0.slug] ?? $0 }
                _ = try acceptRebuild(item, prepared: prepared, snapshot: accepted, durable: durable, includingHeadEdit: false)
            } else {
                let observation = try await prepareRebuild(item, durable: durable)
                guard observation.stable else { throw SyncError.ingestIncomplete }
                _ = try acceptRebuild(item, prepared: observation.value, snapshot: observation.value.snapshot,
                                      durable: durable, includingHeadEdit: false)
                StoreIngestState.shared(for: item.presentation.context.container)
                    .accept(observation.ingest, result: RebuildResult())
            }
            if item.wasCancelled { item.removedSkillDeletion?.didCancel() }
            return nil
        } catch {
            return rebuildFailure(error, item: item, manifestSaved: published)
        }
    }

    @MainActor
    func saveWithStableHead(_ item: Item, disk: inout ManifestSnapshot?, first: ManifestRead) async throws -> SaveResult {
        if item.wasCancelled {
            disk = first.disk
            refreshRefused(durable: disk)
            let durable = try disk ?? item.fallback()
            let error = await rebuild(item, durable: durable, published: false)
            return SaveResult(published: false, error: error)
        }
        let ingest = StoreIngestState.shared(for: item.presentation.context.container)
        var acceptedFinalAttempt = false
        for attempt in 0..<3 {
            acceptedFinalAttempt = false
            // Read refusals have the same meaning on the first attempt and on a retry.
            let read = attempt == 0 ? first : try await readCurrentManifest()
            disk = read.disk
            if disk == nil, ingest.needsRebuild { throw ManifestError.damaged }
            refreshRefused(durable: disk)
            var prepared: PreparedStoreRebuild?
            var head = read.head
            if attempt > 0 || ingest.requiresRebuild(at: read.head) {
                let before = read.head
                let durable: ManifestSnapshot
                let observation: RebuildObservation
                let verdict: HeadEditVerdict
                do {
                    durable = try disk ?? item.fallback()
                    observation = try await prepareRebuild(item, durable: durable)
                    // The bracket starts before the manifest read, not just before the skill scan.
                    guard observation.stable, before == observation.before else { continue }
                    verdict = try acceptRebuild(item, prepared: observation.value,
                                                snapshot: observation.value.snapshot, durable: durable,
                                                includingHeadEdit: true)
                    ingest.accept(observation.ingest, result: RebuildResult())
                    acceptedFinalAttempt = true
                } catch { throw rebuildFailure(error, item: item, manifestSaved: item.wasHealed) }
                switch verdict {
                case .ready(let scan): prepared = scan
                case .refused(let error): throw error
                }
                head = observation.after
            }
            // Check again on the publication worker, after acceptance and immediately before writing.
            guard let result = try await publish(item, disk: disk, head: head) else { continue }
            return await finishPublication(result, item: item, prepared: prepared)
        }
        if acceptedFinalAttempt { throw SyncError.ingestIncomplete }
        throw rebuildFailure(SyncError.ingestIncomplete, item: item, manifestSaved: item.wasHealed)
    }

    private func finishPublication(_ result: Publication, item: Item,
                                   prepared: PreparedStoreRebuild?) async -> SaveResult {
        switch result {
        case .headChanged:
            return SaveResult(published: true, error: ManifestSaveError.rebuildFailed(
                "the store changed on disk at the same moment. Pensieve reads it again before your next change.",
                manifestSaved: true))
        case .saved(let snapshot), .skipped(let snapshot):
            let published: Bool = if case .saved = result { true } else { false }
            let error = await rebuild(item, durable: snapshot, published: published, prepared: prepared)
            return SaveResult(published: published, error: error)
        }
    }

    private func rebuildFailure(_ error: Error, item: Item, manifestSaved: Bool) -> ManifestSaveError {
        StoreIngestState.shared(for: item.presentation.context.container).invalidate()
        let cause = (error as? StoreIngestFailure)?.cause ?? error.localizedDescription
        return .rebuildFailed(cause, manifestSaved: manifestSaved)
    }

    @MainActor
    private func prepareRebuild(_ item: Item, durable: ManifestSnapshot) async throws
        -> RebuildObservation {
        let container = item.presentation.context.container, files = files, manifest = manifest, root = root
        return try await BlockingWork.run {
            let stamp = GitHeadStamp(fileService: files)
            let before = stamp.state(root: root)
            let prepared = try StoreRebuildService(fileService: files, manifestService: manifest)
                .prepare(snapshot: durable, fromRoot: root, container: container, manifest: manifest)
            return RebuildObservation(value: prepared, before: before, after: stamp.state(root: root))
        }
    }

    @MainActor
    private func acceptRebuild(_ item: Item, prepared: PreparedStoreRebuild, snapshot: ManifestSnapshot,
                               durable: ManifestSnapshot, includingHeadEdit: Bool) throws -> HeadEditVerdict {
        var displayed = snapshot
        let creates = knownCreates
        // The scan can synthesize an overlay from a folder before its create is on disk.
        // Only the actual durable manifest can say the move has already been published.
        let needsMoveWindow = (refused + items.map(\.presentation)).contains {
            $0.context === item.presentation.context && $0.intentMove != nil
        }
        let local = needsMoveWindow ? (try? manifest.snapshot(from: item.presentation.context)) : nil
        for edit in refused where edit.context === item.presentation.context {
            edit.project(onto: &displayed, knownCreates: creates, local: local, durable: durable)
        }
        var verdict = HeadEditVerdict.ready(prepared)
        if includingHeadEdit, !item.wasHealed {
            do {
                if case .createSkill = item.change {
                    item.presentation.cache(local: item.intentMove == nil
                        ? try? manifest.snapshot(from: item.presentation.context) : local)
                    item.presentation.project(onto: &displayed, knownCreates: creates, local: local, durable: durable)
                } else {
                    try item.change.validate(in: displayed)
                    item.change.apply(to: &displayed)
                }
            } catch {
                if case ManifestSaveError.renameTaken = error { return .refused(error) }
                // Restore identity before name-based acceptance; report and reconcile afterwards.
                stageCategoryRefusal(item, durable: snapshot, error: error)
                verdict = .refused(error)
            }
        }
        try projectPending(in: item.presentation.context, onto: &displayed, local: local, durable: durable)
        try item.accept(prepared, displayed)
        return verdict
    }
}

enum ManifestSaveError: LocalizedError {
    case rebuildFailed(String, manifestSaved: Bool)
    case unsavedTarget
    case createCollision(String)
    case renameTaken(String)
    case renameRestoreFailed(String)
    var showsDirectly: Bool {
        switch self {
        case .rebuildFailed, .createCollision, .renameTaken, .renameRestoreFailed: true
        case .unsavedTarget: false
        }
    }
    var errorDescription: String? {
        switch self {
        case .rebuildFailed(let message, let manifestSaved):
            (manifestSaved ? "The sync manifest was saved, but rebuilding the local store failed: "
                : "Rebuilding the local store failed: ") + message
        case .unsavedTarget: "This change depends on an earlier change that could not be saved."
        case .renameRestoreFailed(let message): message
        case .renameTaken(let slug):
            "The name “\(slug)” is taken by a skill on another Mac, so this rename wasn't saved to the synced library."
        case .createCollision(let slug):
            "Another Mac already has a skill named “\(slug)”. Rename this skill to keep its tags and scope; "
                + "they aren't saved until you do."
        }
    }
}
