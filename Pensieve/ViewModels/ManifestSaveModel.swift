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
    /// Nil until a disk read or an accepted launch/sync verdict supplies the current state.
    var requiresNewerVersion: Bool?
    @ObservationIgnored var damageObservationOrder = 0
    @ObservationIgnored var damageRefreshOrder: Int?
    @ObservationIgnored var didReadRepairedLibrary: () async -> Void = {}
    var repairError: String?
    @ObservationIgnored var damage: ManifestDamage?
    @ObservationIgnored var confirmedDamage: ManifestDamage?
    var pausedForRepair = false
    var hasActiveSaves: Bool { pendingCount > 0 && !pausedForRepair }
    @ObservationIgnored var refused: [ManifestRefusedEdit] = []
    @ObservationIgnored private var categoryMessages: [CategorySaveNotice.Entry] = []
    @ObservationIgnored var stagedRefusals: [UUID: () -> Void] = [:]
    @ObservationIgnored var worker: Task<Void, Never>?

    struct Item {
        var id: UUID { presentation.id }
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
            let outcome = await save(items[0])
            if case .retry = outcome { continue }
            if case .finished(let saved) = outcome { savedAny = saved || savedAny }
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

    private enum SaveOutcome { case finished(Bool), retry, paused }

    @MainActor
    private func save(_ item: Item) async -> SaveOutcome {
        var disk: ManifestSnapshot?
        var heldLock: SyncLock?
        var outcome = SaveOutcome.finished(false)
        var report: (() -> Void)?
        var needsDamageRefresh = false
        do {
            heldLock = try await takeLock()
            let read = try await readCurrentManifest()
            let result = try await saveWithStableHead(item, disk: &disk, first: read)
            outcome = .finished(result.published)
            report = { item.report(result.error) }
        } catch {
            if case ManifestError.damaged = error {
                outcome = .paused
                needsDamageRefresh = true
            } else if item.categoryEdit != nil {
                stageCategoryRefusal(item, durable: disk, error: error)
            } else {
                let acknowledged = retainUnsaved(item, durable: disk)
                outcome = .finished(acknowledged)
                let refusal = disk.flatMap { item.change.conflictingCreate(in: $0) }
                    .map { ManifestSaveError.skillAlreadyExists($0) as Error } ?? error
                if case ManifestSaveError.rebuildFailed = error { report = { item.report(error) } } else {
                    report = { item.report(item.wasHealed || acknowledged ? nil : refusal) }
                }
            }
        }
        // Transfer projections and complete category undo under the lock. All callbacks,
        // including repair refresh and category reconciliation, pass this single release point.
        if case .finished = outcome {
            StoreIngestState.shared(for: item.presentation.context.container).finish(item.id)
        }
        heldLock?.release()
        finishStagedRefusals()
        if needsDamageRefresh {
            await refreshDamage()
            pausedForRepair = libraryDamaged
            showsDamageAlert = libraryDamaged
            outcome = libraryDamaged ? .paused : .retry
        }
        report?()
        return outcome
    }

    /// Returns true only when this attempt read all requested values durably on disk.
    @MainActor
    private func retainUnsaved(_ item: Item, durable: ManifestSnapshot?) -> Bool {
        guard !item.wasHealed else { return false }
        if durable != nil {
            item.presentation.cache(local: try? manifest.snapshot(from: item.presentation.context))
        }
        if durable.map({ item.presentation.refresh(durable: $0) }) ?? true {
            item.presentation.retain()
            refused.append(item.presentation)
            return false
        }
        StoreIngestState.shared(for: item.presentation.context.container).finish(item.id)
        return true
    }

    @MainActor
    func publish(_ item: Item, disk: ManifestSnapshot?, head: GitHeadStamp.State) async throws
        -> Publication? {
        var saved = try disk ?? item.fallback()
        // A fallback publishes this context's whole window. Capture its queue membership before
        // awaiting the write; another context or an edit submitted during the write is not healed.
        let healedItems = disk == nil ? Set(items.filter {
            $0.presentation.context === item.presentation.context
        }.map(\.id)) : []
        if disk != nil, !item.wasHealed { try item.change.validate(in: saved) }
        if disk != nil, !item.wasHealed, !item.change.apply(to: &saved) {
            if refused.contains(where: { $0.suppliesTarget(for: item.presentation) }) {
                throw ManifestSaveError.unsavedTarget
            }
            if !item.change.isDeletion {
                log("Skipped queued manifest change: its target was removed by sync.")
                return Publication(snapshot: saved, published: false, headChanged: false)
            }
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
        if !item.wasHealed, let disk, let slug = item.change.conflictingCreate(in: disk) {
            throw ManifestSaveError.skillAlreadyExists(slug)
        }
        ingest.finish(item.id)
        for index in items.indices where healedItems.contains(items[index].id) {
            items[index].wasHealed = true
            ingest.finish(items[index].id)
        }
        refused = refused.filter { $0.acknowledge(durable: saved) }
        return Publication(snapshot: saved, published: true, headChanged: headChanged)
    }

    @MainActor
    func projectPending(in context: ModelContext, onto snapshot: inout ManifestSnapshot) throws {
        for pending in items.dropFirst() where !pending.wasHealed
            && pending.categoryEdit?.wasRebuilt != true && pending.presentation.context === context
            && items.contains(where: { $0.id == pending.id }) {
            do { try pending.change.validate(in: snapshot) } catch {
                guard pending.categoryEdit != nil else { throw error }
                // Reject before accepting two same-named records, which would make name-based
                // rebuild matching associate our UUID with the peer's rule. This head's snapshot
                // is not publication evidence for the pending edit.
                stageCategoryRefusal(pending, durable: nil, error: error)
                items.removeAll { $0.id == pending.id }
                StoreIngestState.shared(for: context.container).finish(pending.id)
                pendingCount = items.count
                continue
            }
            pending.change.apply(to: &snapshot)
        }
    }

    @MainActor
    func refreshRefused(durable: ManifestSnapshot?) {
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
    func stageCategoryRefusal(_ item: Item, durable: ManifestSnapshot?, error: Error) {
        guard stagedRefusals[item.id] == nil else { return }
        stagedRefusals[item.id] = prepareCategoryRefusal(item, durable: durable, error: error)
    }

    @MainActor
    func finishStagedRefusals() {
        let completions = stagedRefusals.values
        stagedRefusals = [:]
        for complete in completions { complete() }
    }

    @MainActor
    private func prepareCategoryRefusal(_ item: Item, durable: ManifestSnapshot?, error: Error) -> () -> Void {
        guard let edit = item.categoryEdit, let start = items.firstIndex(where: { $0.id == item.id }) else { return {} }
        if categoryIsSaved(item, durable: durable) {
            return {
                self.categoryMessages.append(CategorySaveNotice.entry(edit: edit, error: error, outcome: .saved))
                item.report(nil)
            }
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
        return restoreCategories(affected, reason: error)
    }

    @MainActor
    private func restoreCategories(_ affected: [Item], reason: Error) -> () -> Void {
        var notices: [CategorySaveNotice.Entry] = []
        var reports: [() -> Void] = []
        for (index, item) in affected.enumerated().reversed() {
            guard let edit = item.categoryEdit else { continue }
            let error = index == 0 ? reason : ManifestSaveError.unsavedTarget
            var wasKept = false
            do {
                let restored = try edit.restore(in: item.presentation.context)
                try item.presentation.context.save()
                notices.append(CategorySaveNotice.entry(edit: edit,
                    error: restored == .saved ? reason : error, outcome: restored))
                wasKept = restored == .saved
            } catch {
                notices.append(CategorySaveNotice.Entry(
                    text: "Couldn't restore “\(edit.name)”: " + error.localizedDescription, wasKept: false))
                log("Category undo failed: " + error.localizedDescription)
            }
            reports.append { item.report(wasKept ? nil : error) }
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
        return {
            self.categoryMessages.append(contentsOf: notices)
            for report in reports { report() }
            if let reconcile = affected.compactMap(\.reconcile).first {
                let result = reconcile()
                if result.hasFailures { self.log("Restored category deployments need another reconcile.") }
            }
        }
    }
}

enum ManifestSaveError: LocalizedError {
    case rebuildFailed(String, manifestSaved: Bool)
    case unsavedTarget
    case skillAlreadyExists(String)
    var errorDescription: String? {
        switch self {
        case .rebuildFailed(let message, let manifestSaved):
            (manifestSaved ? "The sync manifest was saved, but rebuilding the local store failed: "
                : "Rebuilding the local store failed: ") + message
        case .unsavedTarget: "This change depends on an earlier change that could not be saved."
        case .skillAlreadyExists(let slug): "Another Mac already has a skill named “\(slug)”. This create could not be saved."
        }
    }
}
