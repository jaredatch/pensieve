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
    private var unpublishedOwners: Set<ObjectIdentifier> = []

    func setUnpublishedEdits(owner: AnyObject, pending: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let id = ObjectIdentifier(owner)
        if pending { unpublishedOwners.insert(id) } else { unpublishedOwners.remove(id) }
    }

    private var hasUnpublishedEdits: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !unpublishedOwners.isEmpty
    }

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
        let state = shared(for: context.container)
        guard state.needsRebuild else { return }
        guard !state.hasUnpublishedEdits else {
            state.invalidate()
            throw StoreIngestError.unpublishedEdits
        }
        _ = try rebuild(using: service, root: root, context: context)
    }

    /// All sync writers use the same failure admission, including protocol-based rebuild services.
    static func rebuild(using service: StoreRebuildServiceProtocol, root: String,
                        context: ModelContext) throws -> RebuildResult {
        let state = shared(for: context.container)
        let result = service.rebuild(fromRoot: root, context: context)
        state.record(result)
        if result.storeUnreadable || result.ingestIncomplete { context.rollback() }
        if result.storeUnreadable { throw SyncError.storeUnreadable(result.warnings) }
        if result.ingestIncomplete { throw SyncError.ingestIncomplete }
        return result
    }
}

enum StoreIngestError: LocalizedError {
    case unpublishedEdits
    var errorDescription: String? { "A library change is still waiting to save. Retry after it saves." }
}
