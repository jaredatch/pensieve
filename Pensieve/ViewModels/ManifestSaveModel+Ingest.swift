import Foundation
import SwiftData

extension ManifestSaveModel {
    enum HeadEditVerdict { case ready(PreparedStoreRebuild), refused(Error) }
    struct PreSaveIngest {
        let verdict: HeadEditVerdict
    }

    struct ManifestRead {
        let disk: ManifestSnapshot?
        let head: GitHeadStamp.State
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
                 prepared: PreparedStoreRebuild? = nil) async {
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
                StoreIngestState.shared(for: item.presentation.context.container).accept(observation, result: RebuildResult())
            }
            item.report(nil)
        } catch {
            StoreIngestState.shared(for: item.presentation.context.container).invalidate()
            let cause = (error as? StoreIngestFailure)?.cause ?? error.localizedDescription
            item.report(ManifestSaveError.rebuildFailed(cause, manifestSaved: published))
        }
    }

    @MainActor
    func ingestBeforeSave(_ item: Item, disk: inout ManifestSnapshot?,
                          head: GitHeadStamp.State) async throws -> PreSaveIngest {
        let ingest = StoreIngestState.shared(for: item.presentation.context.container)
        do {
            var before = head
            for attempt in 0..<3 {
                if attempt > 0 {
                    let read = try await readCurrentManifest()
                    disk = read.disk
                    before = read.head
                }
                if disk == nil, ingest.needsRebuild { throw ManifestError.damaged }
                let durable = try disk ?? item.fallback()
                let observation = try await prepareRebuild(item, durable: durable)
                // The bracket starts before the manifest read, not just before the skill scan.
                guard observation.stable, before.oid == observation.before else { continue }
                let verdict = try acceptRebuild(item, prepared: observation.value,
                                                durable: observation.value.snapshot, includingHeadEdit: true)
                ingest.accept(observation, result: RebuildResult())
                return PreSaveIngest(verdict: verdict)
            }
            throw SyncError.ingestIncomplete
        } catch {
            ingest.invalidate()
            if case ManifestError.damaged = error { throw error }
            let cause = (error as? StoreIngestFailure)?.cause ?? error.localizedDescription
            throw ManifestSaveError.rebuildFailed(cause, manifestSaved: item.wasHealed)
        }
    }

    @MainActor
    private func prepareRebuild(_ item: Item, durable: ManifestSnapshot) async throws
        -> StoreIngestState.Observation<PreparedStoreRebuild> {
        let container = item.presentation.context.container, files = files, manifest = manifest, root = root
        return try await BlockingWork.run {
            try StoreIngestState.observe(head: { GitHeadStamp(fileService: files).read(root: root) }, rebuild: {
                try StoreRebuildService(fileService: files, manifestService: manifest)
                    .prepare(snapshot: durable, fromRoot: root, container: container, manifest: manifest)
            })
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
