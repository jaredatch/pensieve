import Foundation
import SwiftData

/// In-memory admission for contexts sharing one library container. Connect and incomplete disk
/// rebuilds invalidate cached HEAD knowledge even when HEAD stays unchanged. Weak container keys
/// retire this state with the library; no marker enters SwiftData or the synced store.
final class StoreIngestState {
    private static let registryLock = NSLock()
    private static let registry = NSMapTable<ModelContainer, StoreIngestState>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
    private let lock = NSLock()
    private var pending = false

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

    /// All sync writers use the same failure admission, including protocol-based rebuild services.
    static func rebuild(using service: StoreRebuildServiceProtocol, root: String,
                        context: ModelContext) throws -> RebuildResult {
        let result = service.rebuild(fromRoot: root, context: context)
        shared(for: context.container).record(result)
        if result.storeUnreadable { throw SyncError.storeUnreadable(result.warnings) }
        if result.ingestIncomplete { throw SyncError.ingestIncomplete }
        return result
    }
}
