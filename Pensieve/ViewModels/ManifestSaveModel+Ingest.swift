import Foundation
import SwiftData

extension ManifestSaveModel {
    @MainActor
    func rebuild(_ item: Item, durable: ManifestSnapshot, published: Bool) async {
        // FIFO retains sync.lock until this result is accepted. The scan's context never commits;
        // a later UI save must not be overwritten while this job reads disk.
        do {
            _ = try await acceptRebuild(item, durable: durable)
            item.report(nil)
        } catch {
            StoreIngestState.shared(for: item.presentation.context.container).invalidate()
            item.report(ManifestSaveError.rebuildFailed(error.localizedDescription, manifestSaved: published))
        }
    }

    @MainActor
    func ingestBeforeSave(_ item: Item, disk: ManifestSnapshot?) async throws -> Bool {
        do {
            return try await acceptRebuild(item, durable: disk ?? item.fallback(), includingHeadEdit: true)
        } catch {
            StoreIngestState.shared(for: item.presentation.context.container).invalidate()
            throw ManifestSaveError.rebuildFailed(error.localizedDescription, manifestSaved: item.wasHealed)
        }
    }

    @MainActor
    func acceptRebuild(_ item: Item, durable: ManifestSnapshot, includingHeadEdit: Bool = false) async throws -> Bool {
        let container = item.presentation.context.container, files = files, manifest = manifest, root = root
        let (prepared, head) = try await BlockingWork.run {
            let head = GitHeadStamp(fileService: files).read(root: root)
            let prepared = try StoreRebuildService(fileService: files, manifestService: manifest)
                .prepare(snapshot: durable, fromRoot: root, container: container, manifest: manifest)
            guard GitHeadStamp(fileService: files).read(root: root) == head else { throw SyncError.ingestIncomplete }
            return (prepared, head)
        }
        var displayed = prepared.snapshot
        for edit in refused where edit.context === item.presentation.context { edit.project(onto: &displayed) }
        // Publication is permanent, even after a peer changes the manifest. Only edits still
        // awaiting publication and still shown locally need an overlay. An authoritative sync
        // rebuild already replaced older category edits with saved state.
        var mayPublish = true
        if includingHeadEdit, !item.wasHealed {
            do {
                try item.change.validate(in: displayed)
                item.change.apply(to: &displayed)
            } catch {
                // Undo before name-based acceptance can reuse this edit's row for the peer's
                // category. A refused edit does not prevent accepting the completed ingest.
                refuseCategory(item, durable: durable, error: error)
                mayPublish = false
            }
        }
        try projectPending(in: item.presentation.context, onto: &displayed)
        try item.accept(prepared, displayed)
        StoreIngestState.shared(for: container).record(RebuildResult(), head: head)
        return mayPublish
    }

}
