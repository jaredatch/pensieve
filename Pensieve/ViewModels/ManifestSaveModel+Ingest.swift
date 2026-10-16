import Foundation
import SwiftData

extension ManifestSaveModel {
    enum HeadEditVerdict { case ready(PreparedStoreRebuild), refused(Error) }
    struct PreSaveIngest {
        let durable: ManifestSnapshot
        let verdict: HeadEditVerdict
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
    func ingestBeforeSave(_ item: Item, disk: ManifestSnapshot?) async throws -> PreSaveIngest {
        do {
            var durable = try disk ?? item.fallback()
            for attempt in 0..<3 {
                let observation = try await prepareRebuild(item, durable: durable)
                if observation.stable {
                    let verdict = try acceptRebuild(item, prepared: observation.value,
                                                    durable: observation.value.snapshot, includingHeadEdit: true)
                    StoreIngestState.shared(for: item.presentation.context.container).accept(observation, result: RebuildResult())
                    return PreSaveIngest(durable: durable, verdict: verdict)
                }
                guard attempt < 2 else { throw SyncError.ingestIncomplete }
                guard let current = try await readCurrentManifest() else { throw ManifestError.damaged }
                durable = current
            }
            throw SyncError.ingestIncomplete
        } catch {
            StoreIngestState.shared(for: item.presentation.context.container).invalidate()
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
