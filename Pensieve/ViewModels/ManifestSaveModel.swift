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
        let accept: (ManifestSnapshot) throws -> Void
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

    func submit(_ change: ManifestChange, context: ModelContext, report: @escaping (Error?) -> Void) {
        precondition(Thread.isMainThread)
        for edit in refused where edit.context === context { edit.observe(change) }
        items.append(Item(change: change, presentation: ManifestRefusedEdit(change, context: context),
            fallback: { try self.manifest.snapshot(from: context) },
            accept: { snapshot in
                let result = StoreRebuildService(fileService: self.files, manifestService: self.manifest)
                    .rebuild(snapshot: snapshot, fromRoot: self.root, context: context)
                if result.saveFailed { throw ManifestSaveError.mergeFailed(result.warnings.joined(separator: " ")) }
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
            let item = items[0]
            var readDisk = false
            do {
                let lock = try await takeLock()
                defer { lock.release() }
                let disk = try await readCurrentManifest()
                let manifest = manifest, root = root
                let usingFallback = disk == nil
                var saved: ManifestSnapshot
                if let disk, !usingFallback { saved = disk } else { saved = try item.fallback() }
                if let disk { item.presentation.remember(durable: disk); readDisk = true }
                let applied = usingFallback || item.change.apply(to: &saved)
                if applied {
                    let snapshot = saved
                    try await BlockingWork.run { try manifest.write(snapshot, toRoot: root) }
                    savedAny = true
                }
                var displayed = saved
                projectRefused(durable: saved, onto: &displayed)
                if !applied {
                    if refused.contains(where: { $0.suppliesTarget(for: item.presentation) }) {
                        throw ManifestSaveError.unsavedTarget
                    }
                    log("Skipped queued manifest change: its target was removed by sync.")
                }
                for pending in items.dropFirst() { pending.change.apply(to: &displayed) }
                try item.accept(displayed)
                item.report(nil)
            } catch {
                if readDisk {
                    item.presentation.cache(local: try? manifest.snapshot(from: item.presentation.context),
                        categories: try? item.presentation.context.fetch(FetchDescriptor<Category>()))
                }
                refused.append(item.presentation)
                item.report(error)
            }
            items.removeFirst()
            pendingCount = items.count
            isWaiting = false
        }
        worker = nil
        if savedAny { didSave() }
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
    private func projectRefused(durable: ManifestSnapshot, onto displayed: inout ManifestSnapshot) {
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
        refused = refused.filter { $0.project(durable: durable, supplied: supplied, onto: &displayed) }
    }

    @MainActor
    private func takeLock() async throws -> SyncLock {
        let started = Date()
        while true {
            let path = lockPath
            let lock = try await BlockingWork.run { try SyncLock.tryAcquireReportingErrors(at: path) }
            if let lock { return lock }
            if Date().timeIntervalSince(started) >= waitSeconds { isWaiting = true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func reportCategoryFailure(_ error: Error?) {
        if let error { log("Category mutation saved, but manifest regeneration failed: " + error.localizedDescription) }
    }

    static func logMessage(_ message: String) {
        Logger(subsystem: "com.jaredatch.pensieve", category: "manifest")
            .warning("\(message, privacy: .public)")
    }
}

private enum ManifestSaveError: LocalizedError {
    case mergeFailed(String)
    case unsavedTarget
    var errorDescription: String? {
        switch self {
        case .mergeFailed(let message): message
        case .unsavedTarget: "This change depends on an earlier change that could not be saved."
        }
    }
}
