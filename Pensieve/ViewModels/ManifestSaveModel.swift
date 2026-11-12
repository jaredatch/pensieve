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
    let refusedCreatesPath: String?
    @ObservationIgnored var recordsRequireNewerVersion = false
    @ObservationIgnored var restoredDeletions: [RestoredDeletion] = []
    @ObservationIgnored var recordedCreateSlugs: Set<String> = []
    @ObservationIgnored var preservedPeerSlugs: Set<String> = []
    let manifest: ManifestSnapshotting
    let files: FileServiceProtocol
    private let waitSeconds: TimeInterval
    let log: (String) -> Void
    @ObservationIgnored var items: [Item] = []
    var showsDamageAlert = false
    var showsRepairConfirmation = false
    var libraryDamaged = false
    /// Nil until a disk read or an accepted launch/sync verdict supplies the current state.
    var requiresNewerVersion: Bool?
    @ObservationIgnored var damageObservationOrder = 0
    @ObservationIgnored var damageRefreshOrder: Int?
    @ObservationIgnored var damageRefreshTask: Task<Void, Never>?
    @ObservationIgnored var didReadRepairedLibrary: () async -> Void = {}
    var repairError: String?
    @ObservationIgnored var damage: ManifestDamage?
    @ObservationIgnored var confirmedDamage: ManifestDamage?
    var pausedForRepair = false
    var hasActiveSaves: Bool { pendingCount > 0 && !pausedForRepair }
    @ObservationIgnored var refused: [ManifestRefusedEdit] = []
    private typealias OrderedCategoryNotice = (order: Int, entry: CategorySaveNotice.Entry)
    @ObservationIgnored private var nextOrder = 0
    @ObservationIgnored private var categoryMessages: [OrderedCategoryNotice] = []
    @ObservationIgnored var stagedRefusals: [StagedRefusal] = []
    @ObservationIgnored var worker: Task<Void, Never>?

    struct Item {
        let order: Int
        var id: UUID { presentation.id }
        var wasHealed = false
        var wasCancelled = false
        var restoredDeletion: RestoredDeletion?
        var cancelledRemovedSkillDeletion: (() -> Void)?
        let change: ManifestChange
        let intentMove: ManifestLocalIntentMove?
        let categoryEdit: CategorySaveEdit?
        let reconcile: (() -> BatchResult)?
        let presentation: ManifestRefusedEdit
        let fallback: () throws -> ManifestSnapshot
        let accept: (PreparedStoreRebuild, ManifestSnapshot) throws -> Void
        let report: (Error?) -> Void
    }

    init(manifest: ManifestSnapshotting, root: String, lockPath: String,
         refusedCreatesPath: String? = nil, waitSeconds: TimeInterval = 5, files: FileServiceProtocol = FileService(),
         log: @escaping (String) -> Void = ManifestSaveModel.logMessage) {
        self.refusedCreatesPath = refusedCreatesPath
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
                reconcile: (() -> BatchResult)? = nil, intentMove: ManifestLocalIntentMove? = nil,
                report: @escaping (Error?) -> Void) {
        precondition(Thread.isMainThread)
        for edit in refused where edit.context === context { edit.observe(change) }
        for item in items where item.presentation.context === context { item.presentation.observePending(change) }
        let manifest = manifest, files = files
        let item = Item(order: nextOrder, change: change, intentMove: intentMove, categoryEdit: categoryEdit,
            reconcile: reconcile,
            presentation: ManifestRefusedEdit(change, context: context, order: nextOrder, intentMove: intentMove),
            fallback: { try manifest.snapshot(from: context) },
            accept: { prepared, snapshot in
                try StoreRebuildService(fileService: files, manifestService: manifest)
                    .accept(prepared, snapshot: snapshot, context: context)
            }, report: report)
        nextOrder += 1
        items.append(item)
        persistRefusedCreates()
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
            items.removeFirst()
            pendingCount = items.count
            isWaiting = false
        }
        worker = nil
        isWaiting = false
        if !categoryMessages.isEmpty {
            categoryNotice = CategorySaveNotice(entries: (categoryNotice?.entries ?? [])
                + categoryMessages.sorted { $0.order < $1.order }.map(\.entry))
            categoryMessages = []
        }
        if savedAny { didSave() }
    }

    private enum SaveOutcome { case finished(Bool), retry, paused }

    @MainActor
    private func save(_ queuedItem: Item) async -> SaveOutcome {
        var item = queuedItem
        var disk: ManifestSnapshot?
        var heldLock: SyncLock?
        var outcome = SaveOutcome.finished(false)
        var report: (() -> Void)?
        var needsDamageRefresh = false
        do {
            heldLock = try await takeLock()
            discardReappearedQueuedDeletions()
            item = items.first { $0.id == item.id } ?? item
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
                if case ManifestSaveError.createCollision = error, let disk {
                    // Accept the peer's intents and categories even when HEAD is already ingested;
                    // the retained create supplies only this window's overlay during acceptance.
                    _ = await rebuild(item, durable: disk, published: false)
                }
                outcome = .finished(false)
                if case ManifestSaveError.rebuildFailed = error { report = { item.report(error) } } else {
                    report = { item.report(item.wasHealed || acknowledged ? nil : error) }
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
        if item.wasCancelled { return true }
        guard !item.wasHealed else { return false }
        defer { persistRefusedCreates() }
        if let durable {
            // Creates use creation identity, not the no-op of projecting onto a held slug.
            if case .createSkill = item.change {} else {
                do { try item.change.validate(in: durable) } catch { return false }
            }
            item.presentation.cache(local: try? manifest.snapshot(from: item.presentation.context))
        }
        if let create = refused.first(where: {
            $0.context === item.presentation.context && $0.suppliesTarget(for: item.presentation)
        }) {
            item.presentation.hold(with: create)
        }
        if durable.map({ item.presentation.acknowledge(durable: $0) }) ?? true {
            item.presentation.retain()
            refused.append(item.presentation)
            return false
        }
        return true
    }

    @MainActor
    func projectPending(in context: ModelContext, onto snapshot: inout ManifestSnapshot,
                        local: ManifestSnapshot?, durable: ManifestSnapshot) throws {
        for pending in items.dropFirst() where !pending.wasHealed && !pending.wasCancelled
            && pending.categoryEdit?.wasRebuilt != true && pending.presentation.context === context
            && items.contains(where: { $0.id == pending.id }) {
            if case .createSkill = pending.change {
                pending.presentation.cache(local: pending.intentMove == nil ? try? manifest.snapshot(from: context) : local)
                pending.presentation.project(onto: &snapshot, knownCreates: knownCreates, local: local, durable: durable)
                continue
            }
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
        refused = refused.filter { $0.acknowledge(durable: durable) }
        persistRefusedCreates()
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
        // Otherwise this attempt’s disk read or prepared rebuild snapshot must show the edited field is saved.
        guard let edit = item.categoryEdit, let durable else { return false }
        return edit.isSaved(in: durable)
    }

    @MainActor
    func stageCategoryRefusal(_ item: Item, durable: ManifestSnapshot?, error: Error) {
        guard !stagedRefusals.contains(where: { $0.id == item.id }) else { return }
        stagedRefusals.append(.init(id: item.id, order: item.order,
                                   complete: prepareCategoryRefusal(item, durable: durable, error: error)))
    }

    @MainActor
    func finishStagedRefusals() {
        let completions = stagedRefusals.sorted { $0.order < $1.order }
        stagedRefusals = []
        for completion in completions { completion.complete() }
    }

    @MainActor
    private func prepareCategoryRefusal(_ item: Item, durable: ManifestSnapshot?, error: Error) -> () -> Void {
        guard let edit = item.categoryEdit, let start = items.firstIndex(where: { $0.id == item.id }) else { return {} }
        if categoryIsSaved(item, durable: durable) {
            observeSavedRename(item)
            persistRefusedCreates(excludingPublished: item.id)
            return {
                self.categoryMessages.append((item.order, CategorySaveNotice.entry(edit: edit, error: error, outcome: .saved)))
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
        var notices: [OrderedCategoryNotice] = []
        var reports: [() -> Void] = []
        var undos: [(order: Int, edit: CategorySaveEdit)] = []
        for (index, item) in affected.enumerated().reversed() {
            guard let edit = item.categoryEdit else { continue }
            let error = index == 0 ? reason : ManifestSaveError.unsavedTarget
            var wasKept = false
            do {
                let restored = try edit.restore(in: item.presentation.context)
                try item.presentation.context.save()
                if restored == .undone { undos.append((item.order, edit)) }
                notices.append((item.order, CategorySaveNotice.entry(edit: edit,
                    error: restored == .saved ? reason : error, outcome: restored)))
                wasKept = restored == .saved
            } catch {
                notices.append((item.order, CategorySaveNotice.Entry(
                    text: "Couldn't restore “\(edit.name)”: " + error.localizedDescription, wasKept: false)))
                log("Category undo failed: " + error.localizedDescription)
            }
            reports.append { item.report(wasKept ? nil : error) }
        }
        if let context = affected.first?.presentation.context {
            preserveRetirements(in: context, undoing: undos)
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

    @MainActor
    private func preserveRetirements(in context: ModelContext, undoing undos: [(order: Int, edit: CategorySaveEdit)]) {
        do {
            let categories = try context.fetch(FetchDescriptor<Category>())
            for edit in refused where edit.context === context { edit.preserveRetirement(in: categories, undoing: undos) }
            for item in items where item.presentation.context === context {
                item.presentation.preserveRetirement(in: categories, undoing: undos)
            }
            try context.save()
        } catch { log("Couldn't preserve skill retirement during category undo: " + error.localizedDescription) }
    }
}
