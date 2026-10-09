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
    @ObservationIgnored private var worker: Task<Void, Never>?

    private struct Item {
        let change: ManifestChange
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
        items.append(Item(change: change, fallback: { try self.manifest.snapshot(from: context) },
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
            do {
                let lock = try await takeLock()
                defer { lock.release() }
                // The fallback is used only for an unreadable tree; take it after waiting, so it
                // includes edits made during the wait. No ModelContext enters the native job.
                let fallback = try item.fallback()
                let manifest = manifest, root = root, change = item.change, files = files
                let (saved, applied) = try await BlockingWork.run {
                    var snapshot: ManifestSnapshot
                    var usingFallback = false
                    do {
                        usingFallback = !files.fileExists(at: root + "/manifest/manifest.yaml")
                        snapshot = usingFallback ? fallback : try manifest.read(fromRoot: root)
                    } catch {
                        if case ManifestError.unsupportedSchema = error { throw error }
                        snapshot = fallback
                        usingFallback = true
                    }
                    let applied = usingFallback || change.apply(to: &snapshot)
                    if applied { try manifest.write(snapshot, toRoot: root) }
                    return (snapshot, applied)
                }
                savedAny = savedAny || applied
                if !applied { log("Skipped queued manifest change: its target was removed by sync.") }
                var displayed = saved
                for pending in items.dropFirst() { pending.change.apply(to: &displayed) }
                try item.accept(displayed)
                item.report(nil)
            } catch { item.report(error) }
            items.removeFirst()
            pendingCount = items.count
            isWaiting = false
        }
        worker = nil
        if savedAny { didSave() }
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
    var errorDescription: String? {
        switch self {
        case .mergeFailed(let message): message
        }
    }
}
