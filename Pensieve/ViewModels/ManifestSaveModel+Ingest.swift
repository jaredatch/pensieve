import Foundation
import SwiftData

extension ManifestSaveModel {
    static let headMovedCause = "the store changed on disk at the same moment. Pensieve reads it again before your next change."

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
                _ = try acceptRebuild(item, prepared: prepared, durable: accepted, includingHeadEdit: false)
            } else {
                let observation = try await prepareRebuild(item, durable: durable)
                guard observation.stable else { throw SyncError.ingestIncomplete }
                _ = try acceptRebuild(item, prepared: observation.value, durable: observation.value.snapshot,
                                      includingHeadEdit: false)
                StoreIngestState.shared(for: item.presentation.context.container)
                    .accept(observation.ingest, result: RebuildResult())
            }
            return nil
        } catch {
            return rebuildFailure(error, item: item, manifestSaved: published)
        }
    }

    @MainActor
    func saveWithStableHead(_ item: Item, disk: inout ManifestSnapshot?, first: ManifestRead) async throws -> SaveResult {
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
                                                durable: observation.value.snapshot, includingHeadEdit: true)
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
                Self.headMovedCause,
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
    private func acceptRebuild(_ item: Item, prepared: PreparedStoreRebuild, durable: ManifestSnapshot,
                               includingHeadEdit: Bool) throws -> HeadEditVerdict {
        var displayed = durable
        for edit in refused where edit.context === item.presentation.context { edit.project(onto: &displayed) }
        var verdict = HeadEditVerdict.ready(prepared)
        if includingHeadEdit, !item.wasHealed {
            do {
                try item.change.validate(in: displayed)
                item.change.apply(to: &displayed)
            } catch {
                // Restore identity before name-based acceptance; report and reconcile afterwards.
                stageCategoryRefusal(item, durable: durable, error: error)
                verdict = .refused(error)
            }
        }
        try projectPending(in: item.presentation.context, onto: &displayed)
        try item.accept(prepared, displayed)
        return verdict
    }
}
