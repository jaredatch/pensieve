import Foundation
import Observation
import os
import SwiftData

/// Process-owned FIFO for GUI manifest edits. Only plain values cross into BlockingWork; the
/// submitting context stays on the main thread. sync.lock precedes ManifestService's leaf lock.
@Observable
final class ManifestSaveModel {
    static let waitingMessage = "Your change will save when sync finishes."
    private(set) var pendingCount = 0
    private(set) var isWaiting = false
    var statusMessage: String? { isWaiting ? Self.waitingMessage : nil }
    @ObservationIgnored var didSave: SyncStateNotifying = SyncStateNotifier.suppressed
    let lockPath: String
    private let root: String
    private let manifest: ManifestSnapshotting
    private let files: FileServiceProtocol
    private let waitSeconds: TimeInterval
    private let log: (String) -> Void
    @ObservationIgnored private var items: [Item] = []
    @ObservationIgnored private var refused: [ManifestRefusedEdit] = []
    @ObservationIgnored private var worker: Task<Void, Never>?

    private struct Item {
        let change: ManifestChange
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

    func submit(_ change: ManifestChange, context: ModelContext, categoryID: UUID? = nil,
                report: @escaping (Error?) -> Void) {
        precondition(Thread.isMainThread)
        for edit in refused where edit.context === context { edit.observe(change) }
        items.append(Item(change: change, presentation: ManifestRefusedEdit(change, context: context, categoryID: categoryID),
            fallback: { try self.manifest.snapshot(from: context) },
            accept: { prepared, snapshot in
                try StoreRebuildService(fileService: self.files, manifestService: self.manifest)
                    .accept(prepared, snapshot: snapshot, context: context)
            }, report: report))
        pendingCount = items.count
        guard worker == nil else { return }
        worker = Task { @MainActor in await self.drain() }
    }

    @MainActor
    func waitUntilIdle() async {
        while let worker { await worker.value }
    }

    @MainActor
    private func drain() async {
        var savedAny = false
        while !items.isEmpty {
            savedAny = await save(items[0]) || savedAny
            items.removeFirst()
            pendingCount = items.count
            isWaiting = false
        }
        worker = nil
        if savedAny { didSave() }
    }

    @MainActor
    private func save(_ item: Item) async -> Bool {
        var disk: ManifestSnapshot?
        do {
            let lock = try await takeLock()
            defer { lock.release() }
            disk = try await readCurrentManifest()
            if let disk {
                item.presentation.remember(durable: disk)
                refreshRefused(durable: disk)
            }
            let result = try await publish(item, disk: disk)
            await rebuild(item, durable: result.snapshot)
            return result.published
        } catch {
            if disk != nil {
                item.presentation.cache(local: try? manifest.snapshot(from: item.presentation.context),
                    categories: try? item.presentation.context.fetch(FetchDescriptor<Category>()))
            }
            refused.append(item.presentation)
            item.report(error)
            return false
        }
    }

    @MainActor
    private func publish(_ item: Item, disk: ManifestSnapshot?) async throws
        -> (snapshot: ManifestSnapshot, published: Bool) {
        var saved = try disk ?? item.fallback()
        if disk != nil, !item.change.hasTarget(in: saved) {
            if refused.contains(where: { $0.suppliesTarget(for: item.presentation) }) {
                throw ManifestSaveError.unsavedTarget
            }
            log("Skipped queued manifest change: its target was removed by sync.")
            return (saved, false)
        }
        if disk != nil { item.change.apply(to: &saved) }
        let snapshot = saved, manifest = manifest, root = root
        try await BlockingWork.run { try manifest.write(snapshot, toRoot: root) }
        if let disk { for edit in refused { edit.rememberLocalWrite(before: disk, after: saved) } }
        refused = refused.filter { $0.acknowledge(durable: saved) }
        return (saved, true)
    }

    @MainActor
    private func rebuild(_ item: Item, durable: ManifestSnapshot) async {
        // FIFO retains sync.lock until this result is accepted. The scan's context never commits;
        // a later UI save must not be overwritten while this job reads disk.
        do {
            let container = item.presentation.context.container, files = files, manifest = manifest, root = root
            let prepared = try await BlockingWork.run {
                try StoreRebuildService(fileService: files, manifestService: manifest)
                    .prepare(snapshot: durable, fromRoot: root, container: container, manifest: manifest)
            }
            var displayed = prepared.snapshot
            for edit in refused { edit.project(onto: &displayed) }
            for pending in items.dropFirst() { pending.change.apply(to: &displayed) }
            try item.accept(prepared, displayed)
            item.report(nil)
        } catch {
            item.report(ManifestSaveError.rebuildFailed(error.localizedDescription))
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
                return nil
            }
        }
    }

    @MainActor
    private func refreshRefused(durable: ManifestSnapshot) {
        var locals: [ObjectIdentifier: (ManifestSnapshot?, [Category]?)] = [:]
        for edit in refused {
            let key = ObjectIdentifier(edit.context)
            if locals[key] == nil {
                do {
                    locals[key] = (try manifest.snapshot(from: edit.context),
                        try edit.context.fetch(FetchDescriptor<Category>()))
                } catch {
                    log("Couldn't refresh a refused edit's presentation: " + error.localizedDescription)
                    locals[key] = (nil, nil)
                }
            }
            if let (local, categories) = locals[key] { edit.cache(local: local, categories: categories) }
        }
        let supplied = Set(refused.compactMap { $0.suppliesCategory(in: durable) })
        refused = refused.filter { $0.refresh(durable: durable, supplied: supplied) }
    }

    @MainActor
    private func takeLock() async throws -> SyncLock {
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
            } else { log("Category mutation saved, but manifest regeneration failed: " + error.localizedDescription) }
        }
    }

    static func logMessage(_ message: String) {
        Logger(subsystem: "com.jaredatch.pensieve", category: "manifest")
            .warning("\(message, privacy: .public)")
    }
}

enum ManifestSaveError: LocalizedError {
    case rebuildFailed(String)
    case unsavedTarget
    var errorDescription: String? {
        switch self {
        case .rebuildFailed(let message): "The sync manifest was saved, but rebuilding the local store failed: " + message
        case .unsavedTarget: "This change depends on an earlier change that could not be saved."
        }
    }
}
