import Foundation
import SwiftData

/// In-memory admission for contexts sharing one library container. Connect and incomplete disk
/// rebuilds invalidate cached HEAD knowledge even when HEAD stays unchanged. Registry keys are
/// weak; values may linger until NSMapTable cleans up. No marker enters SwiftData or the synced store.
final class StoreIngestState {
    private static let registryLock = NSLock()
    private static let registry = NSMapTable<ModelContainer, StoreIngestState>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
    private let lock = NSLock()
    private var pending = false
    private struct QueuedEdit {
        let id: UUID
        let change: ManifestChange
        let categoryWindow: UUID?
    }
    private var edits: [QueuedEdit] = []

    static func shared(for container: ModelContainer) -> StoreIngestState {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let state = registry.object(forKey: container) { return state }
        let state = StoreIngestState()
        registry.setObject(state, forKey: container)
        return state
    }

    var needsRebuild: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    func enqueue(_ change: ManifestChange, id: UUID, categoryWindow: UUID?) {
        lock.lock()
        defer { lock.unlock() }
        edits.append(QueuedEdit(id: id, change: change, categoryWindow: categoryWindow))
    }

    func finish(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        edits.removeAll { $0.id == id }
    }

    /// Plain edits cross contexts; SwiftData objects remain on their owning executor.
    func projectingEdits(onto snapshot: ManifestSnapshot) -> (snapshot: ManifestSnapshot, retainedWindows: Set<UUID>) {
        lock.lock()
        let changes = edits
        lock.unlock()
        var projected = snapshot
        var retained: Set<UUID> = []
        for edit in changes {
            let change = edit.change
            do { try change.validate(in: projected) } catch { continue }
            let before = projected.categories
            change.apply(to: &projected)
            if let window = edit.categoryWindow, before != projected.categories { retained.insert(window) }
        }
        return (projected, retained)
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        pending = true
    }

    func record(_ result: RebuildResult) {
        lock.lock()
        defer { lock.unlock() }
        pending = result.storeUnreadable || result.ingestIncomplete
    }

    /// Writers call this under sync.lock, before applying their local edit. Rebuilding after
    /// the edit could replace it with the still-pending disk snapshot.
    static func rebuildIfNeeded(using service: StoreRebuildServiceProtocol, root: String,
                                context: ModelContext) throws {
        guard shared(for: context.container).needsRebuild else { return }
        _ = try rebuild(using: service, root: root, context: context)
    }

    /// All sync writers use the same failure admission, including protocol-based rebuild services.
    static func rebuild(using service: StoreRebuildServiceProtocol, root: String,
                        context: ModelContext) throws -> RebuildResult {
        let result = service.rebuild(fromRoot: root, context: context)
        shared(for: context.container).record(result)
        if result.manifestDamaged { throw ManifestError.damaged }
        if result.storeUnreadable { throw SyncError.storeUnreadable(result.warnings) }
        if result.ingestIncomplete { throw SyncError.ingestIncomplete }
        return result
    }
}
