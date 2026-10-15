import Foundation
import Observation
import os
import SwiftData

/// Process-owned FIFO for GUI manifest edits. Only plain values cross into BlockingWork; the
/// submitting context stays on the main thread. sync.lock precedes ManifestService's leaf lock.
/// Only the main window's context submits today. A second context sharing its container needs
/// the healing snapshot and rebuild overlays revisited before submitting here.
@Observable
final class ManifestSaveModel {
    static let waitingMessage = "Your change will save when sync finishes."
    private(set) var pendingCount = 0
    var isWaiting = false
    var categoryNotice: CategorySaveNotice?
    var statusMessage: String? { isWaiting ? Self.waitingMessage : nil }
    @ObservationIgnored var didSave: SyncStateNotifying = SyncStateNotifier.suppressed
    let lockPath: String
    let root: String
    let manifest: ManifestSnapshotting
    let files: FileServiceProtocol
    private let waitSeconds: TimeInterval
    private let log: (String) -> Void
    @ObservationIgnored var items: [Item] = []
    var showsDamageAlert = false
    var showsRepairConfirmation = false
    var libraryDamaged = false
    var repairError: String?
    @ObservationIgnored var damage: ManifestDamage?
    @ObservationIgnored var confirmedDamage: ManifestDamage?
    @ObservationIgnored var pausedForRepair = false
    @ObservationIgnored private var refused: [ManifestRefusedEdit] = []
    @ObservationIgnored private var categoryMessages: [CategorySaveNotice.Entry] = []
    @ObservationIgnored var worker: Task<Void, Never>?

    struct Item {
        let id = UUID()
        var wasHealed = false
        let change: ManifestChange
        let categoryEdit: CategorySaveEdit?
        let reconcile: (() -> BatchResult)?
        let presentation: ManifestRefusedEdit
        let fallback: () throws -> ManifestSnapshot
        let accept: (PreparedStoreRebuild, ManifestSnapshot) throws -> Void
        let report: (Error?) -> Void
    }

    init(manifest: ManifestSnapshotting, root: String, lockPath: String,
         waitSeconds: TimeInterval = 5, files: FileServiceProtocol = FileService(),
         log: @escaping (String) -> Void = ManifestSaveModel.logMessage) {
        self.files = files
        self.manifest = manifest
        self.root = root
        self.lockPath = lockPath
        self.waitSeconds = waitSeconds
        self.log = log
    }

    deinit {
        for item in items { StoreIngestState.shared(for: item.presentation.context.container).finish(item.id) }
    }

    func submit(_ change: ManifestChange, context: ModelContext, categoryEdit: CategorySaveEdit? = nil,
                reconcile: (() -> BatchResult)? = nil, report: @escaping (Error?) -> Void) {
        precondition(Thread.isMainThread)
        for edit in refused where edit.context === context { edit.observe(change) }
        let manifest = manifest, files = files
        let item = Item(change: change, categoryEdit: categoryEdit, reconcile: reconcile,
            presentation: ManifestRefusedEdit(change, context: context),
            fallback: { try manifest.snapshot(from: context) },
            accept: { prepared, snapshot in
                try StoreRebuildService(fileService: files, manifestService: manifest)
                    .accept(prepared, snapshot: snapshot, context: context)
            }, report: report)
        items.append(item)
        StoreIngestState.shared(for: context.container).enqueue(change, id: item.id, categoryWindow: categoryEdit?.windowID)
        pendingCount = items.count
        guard worker == nil else { return }
        worker = Task { @MainActor in await self.drain() }
    }

    @MainActor
    func waitUntilIdle() async {
        while let worker { await worker.value }
    }

    @MainActor
    func drain() async {
        var savedAny = false
        pausedForRepair = false
        while !items.isEmpty {
            savedAny = await save(items[0]) || savedAny
            if pausedForRepair { break }
            let finished = items.removeFirst()
            StoreIngestState.shared(for: finished.presentation.context.container).finish(finished.id)
            pendingCount = items.count
            isWaiting = false
        }
        worker = nil
        isWaiting = false
        if !categoryMessages.isEmpty {
            categoryNotice = CategorySaveNotice(entries: (categoryNotice?.entries ?? []) + categoryMessages)
            categoryMessages = []
        }
        if savedAny { didSave() }
    }

    @MainActor
    private func save(_ item: Item) async -> Bool {
        var disk: ManifestSnapshot?
        var heldLock: SyncLock?
        defer { heldLock?.release() }
        do {
            heldLock = try await takeLock()
            disk = try await readCurrentManifest()
            if disk == nil, StoreIngestState.shared(for: item.presentation.context.container).needsRebuild {
                throw ManifestError.damaged
            }
            refreshRefused(durable: disk)
            let result = try await publish(item, disk: disk)
            await rebuild(item, durable: result.snapshot, published: result.published)
            return result.published
        } catch {
            if case ManifestError.damaged = error {
                pausedForRepair = true
                await refreshDamage()
                showsDamageAlert = true
                for queued in items { queued.report(error) }
                return false
            }
            if item.categoryEdit != nil {
                refuseCategory(item, durable: disk, error: error)
                return false
            }
            heldLock?.release()
            if !item.wasHealed {
                if disk != nil {
                    item.presentation.cache(local: try? manifest.snapshot(from: item.presentation.context))
                }
                refused.append(item.presentation)
            }
            item.report(item.wasHealed ? nil : error)
            return false
        }
    }

    @MainActor
    private func publish(_ item: Item, disk: ManifestSnapshot?) async throws
        -> (snapshot: ManifestSnapshot, published: Bool) {
        var saved = try disk ?? item.fallback()
        // A fallback publishes this context's whole window. Capture its queue membership before
        // awaiting the write; another context or an edit submitted during the write is not healed.
        let healedItems = disk == nil ? Set(items.filter {
            $0.presentation.context === item.presentation.context
        }.map(\.id)) : []
        if disk == nil, StoreIngestState.shared(for: item.presentation.context.container).needsRebuild {
            throw ManifestError.damaged
        }
        if disk != nil, !item.wasHealed { try item.change.validate(in: saved) }
        if disk != nil, !item.wasHealed, !item.change.apply(to: &saved) {
            if refused.contains(where: { $0.suppliesTarget(for: item.presentation) }) {
                throw ManifestSaveError.unsavedTarget
            }
            if !item.change.isDeletion {
                log("Skipped queued manifest change: its target was removed by sync.")
                return (saved, false)
            }
        }
        let snapshot = saved, manifest = manifest, root = root
        try await BlockingWork.run { try manifest.write(snapshot, toRoot: root) }
        let ingest = StoreIngestState.shared(for: item.presentation.context.container)
        ingest.finish(item.id)
        for index in items.indices where healedItems.contains(items[index].id) {
            items[index].wasHealed = true
            ingest.finish(items[index].id)
        }
        refused = refused.filter { $0.acknowledge(durable: saved) }
        return (saved, true)
    }

    @MainActor
    private func rebuild(_ item: Item, durable: ManifestSnapshot, published: Bool) async {
        // FIFO retains sync.lock until this result is accepted. The scan's context never commits;
        // a later UI save must not be overwritten while this job reads disk.
        do {
            let container = item.presentation.context.container, files = files, manifest = manifest, root = root
            let prepared = try await BlockingWork.run {
                try StoreRebuildService(fileService: files, manifestService: manifest)
                    .prepare(snapshot: durable, fromRoot: root, container: container, manifest: manifest)
            }
            var displayed = prepared.snapshot
            for edit in refused where edit.context === item.presentation.context { edit.project(onto: &displayed) }
            // Publication is permanent, even after a peer changes the manifest. Only edits still
            // awaiting publication and still shown locally need an overlay. An authoritative sync
            // rebuild already replaced older category edits with saved state.
            try projectPending(in: item.presentation.context, onto: &displayed)
            try item.accept(prepared, displayed)
            StoreIngestState.shared(for: container).record(RebuildResult())
            item.report(nil)
        } catch {
            StoreIngestState.shared(for: item.presentation.context.container).invalidate()
            item.report(ManifestSaveError.rebuildFailed(error.localizedDescription, manifestSaved: published))
        }
    }

    @MainActor
    private func projectPending(in context: ModelContext, onto snapshot: inout ManifestSnapshot) throws {
        for pending in items.dropFirst() where !pending.wasHealed
            && pending.categoryEdit?.wasRebuilt != true && pending.presentation.context === context
            && items.contains(where: { $0.id == pending.id }) {
            do { try pending.change.validate(in: snapshot) } catch {
                guard pending.categoryEdit != nil else { throw error }
                // Reject before accepting two same-named records, which would make name-based
                // rebuild matching associate our UUID with the peer's rule. This head's snapshot
                // is not publication evidence for the pending edit.
                refuseCategory(pending, durable: nil, error: error)
                items.removeAll { $0.id == pending.id }
                StoreIngestState.shared(for: context.container).finish(pending.id)
                pendingCount = items.count
                continue
            }
            pending.change.apply(to: &snapshot)
        }
    }

    @MainActor
    private func readCurrentManifest() async throws -> ManifestSnapshot? {
        let manifest = manifest, root = root, files = files
        return try await BlockingWork.run {
            do {
                guard files.fileExists(at: root + "/manifest/manifest.yaml") else { return nil }
                return try manifest.read(fromRoot: root)
            } catch {
                if case ManifestError.unsupportedSchema = error { throw error }
                throw ManifestError.damaged
            }
        }
    }

    @MainActor
    private func refreshRefused(durable: ManifestSnapshot?) {
        var locals: [ObjectIdentifier: ManifestSnapshot] = [:]
        var attempted: Set<ObjectIdentifier> = []
        for edit in refused {
            let key = ObjectIdentifier(edit.context)
            if attempted.insert(key).inserted {
                do { locals[key] = try manifest.snapshot(from: edit.context) } catch {
                    log("Couldn't refresh a refused edit's presentation: " + error.localizedDescription)
                }
            }
            edit.cache(local: locals[key])
        }
        guard let durable else { return }
        refused = refused.filter { $0.refresh(durable: durable) }
    }

    @MainActor
    func takeLock() async throws -> SyncLock {
        let path = lockPath
        // Start the clock before the first attempt, including native-worker admission time.
        let deadline = ContinuousClock.now.advanced(by: .seconds(waitSeconds))
        let notice = Task { @MainActor in
            try? await Task.sleep(until: deadline, clock: .continuous)
            if !Task.isCancelled { isWaiting = true }
        }
        defer { notice.cancel() }
        return try await BlockingWork.run { try SyncLock.waitForSave(at: path) }
    }

    func reportCategoryFailure(_ error: Error?) {
        if let error {
            if case ManifestSaveError.rebuildFailed = error {
                log(error.localizedDescription)
            } else { log("Category change could not be saved: " + error.localizedDescription) }
        }
    }

    static func logMessage(_ message: String) {
        Logger(subsystem: "com.jaredatch.pensieve", category: "manifest")
            .warning("\(message, privacy: .public)")
    }
}

extension ManifestSaveModel {
    @MainActor
    private func categoryIsSaved(_ item: Item, durable: ManifestSnapshot?) -> Bool {
        // A successful heal published this item already. Later disk changes cannot revoke it.
        if item.wasHealed { return true }
        // Otherwise only a read from this attempt can establish that the edited field is saved.
        guard let edit = item.categoryEdit, let durable else { return false }
        return edit.isSaved(in: durable)
    }

    @MainActor
    private func refuseCategory(_ item: Item, durable: ManifestSnapshot?, error: Error) {
        guard let edit = item.categoryEdit, let start = items.firstIndex(where: { $0.id == item.id }) else { return }
        if categoryIsSaved(item, durable: durable) {
            categoryMessages.append(CategorySaveNotice.entry(edit: edit, error: error, outcome: .saved))
            item.report(nil)
            return
        }
        var affected = [item]
        var identities: Set<UUID> = [edit.id]
        var restoredNames = Set([edit.restoredName].compactMap { $0 })
        var dependentIndices: [Int] = []
        // A heal marks the head and its queued context together. A healed head returns above,
        // so only unpublished edits in this context can become dependent undos here.
        for index in items.indices.dropFirst(start + 1) {
            let candidate = items[index]
            guard candidate.presentation.context === item.presentation.context,
                  let next = candidate.categoryEdit,
                  identities.contains(next.id) || next.claimedName.map({ claimed in
                      restoredNames.contains { CategoryName.matches(claimed, $0) }
                  }) == true else { continue }
            affected.append(candidate)
            dependentIndices.append(index)
            identities.insert(next.id)
            if let name = next.restoredName { restoredNames.insert(name) }
        }
        for index in dependentIndices.reversed() {
            let removed = items.remove(at: index)
            StoreIngestState.shared(for: removed.presentation.context.container).finish(removed.id)
        }
        restoreCategories(affected, reason: error)
    }

    @MainActor
    private func restoreCategories(_ affected: [Item], reason: Error) {
        for (index, item) in affected.enumerated().reversed() {
            guard let edit = item.categoryEdit else { continue }
            let error = index == 0 ? reason : ManifestSaveError.unsavedTarget
            var wasKept = false
            do {
                let restored = try edit.restore(in: item.presentation.context)
                try item.presentation.context.save()
                categoryMessages.append(CategorySaveNotice.entry(edit: edit,
                    error: restored == .saved ? reason : error, outcome: restored))
                wasKept = restored == .saved
            } catch {
                categoryMessages.append(CategorySaveNotice.Entry(
                    text: "Couldn't restore “\(edit.name)”: " + error.localizedDescription, wasKept: false))
                log("Category undo failed: " + error.localizedDescription)
            }
            item.report(wasKept ? nil : error)
        }
        if let context = affected.first?.presentation.context {
            do {
                let categories = try context.fetch(FetchDescriptor<Category>())
                for edit in refused where edit.context === context { edit.preserveRetirement(in: categories) }
                for item in items where item.presentation.context === context {
                    item.presentation.preserveRetirement(in: categories)
                }
                try context.save()
            } catch { log("Couldn't preserve skill retirement during category undo: " + error.localizedDescription) }
        }
        // All inverses land before convergence, so a dependent rename never briefly takes a name
        // that its parent is about to restore. A missing folder keeps the existing cleanup ledger.
        if let reconcile = affected.compactMap(\.reconcile).first {
            let result = reconcile()
            if result.hasFailures { log("Restored category deployments need another reconcile.") }
        }
    }

}

enum ManifestSaveError: LocalizedError {
    case rebuildFailed(String, manifestSaved: Bool)
    case unsavedTarget
    var errorDescription: String? {
        switch self {
        case .rebuildFailed(let message, let manifestSaved):
            (manifestSaved ? "The sync manifest was saved, but rebuilding the local store failed: "
                : "Rebuilding the local store failed: ") + message
        case .unsavedTarget: "This change depends on an earlier change that could not be saved."
        }
    }
}
