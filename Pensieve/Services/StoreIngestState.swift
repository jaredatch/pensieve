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
    private var ingestedHead: String?
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

    func requiresRebuild(at head: GitHeadStamp.State) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch head {
        case .noRepository, .unborn: return pending
        case .unreadable: return true
        case let .resolved(value): return pending || ingestedHead == nil || value != ingestedHead
        }
    }

    /// The caller just committed its own snapshot under sync.lock, on the admitted parent.
    /// This changes commit identity without introducing unseen store content.
    func recordLocalCommit(from parent: String?, to head: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard !pending, let parent, parent == ingestedHead else { return }
        ingestedHead = head
    }

    /// Launch has already validated this stamp under sync.lock. Do not clear a failed ingest.
    func seedHead(_ head: String?) {
        lock.lock()
        defer { lock.unlock() }
        if !pending { ingestedHead = head }
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
        ingestedHead = nil
    }

    func record(_ result: RebuildResult, head: String?) {
        lock.lock()
        defer { lock.unlock() }
        pending = result.storeUnreadable || result.ingestIncomplete
        ingestedHead = pending ? nil : head
    }

    /// Writers call this under sync.lock, before applying their local edit. Rebuilding after
    /// the edit could replace it with the still-pending disk snapshot.
    static func rebuildIfNeeded(using service: StoreRebuildServiceProtocol, root: String,
                                context: ModelContext, files: FileServiceProtocol = FileService()) throws {
        guard shared(for: context.container).requiresRebuild(at: GitHeadStamp(fileService: files).state(root: root)) else {
            return
        }
        _ = try rebuild(using: service, root: root, context: context, files: files)
    }

    /// All sync writers use the same failure admission, including protocol-based rebuild services.
    static func rebuild(using service: StoreRebuildServiceProtocol, root: String,
                        context: ModelContext, files: FileServiceProtocol = FileService(),
                        headStamp: (() -> String?)? = nil) throws -> RebuildResult {
        let readHead = headStamp ?? { GitHeadStamp(fileService: files).read(root: root) }
        let before = readHead()
        let result = service.rebuild(fromRoot: root, context: context)
        let state = shared(for: context.container)
        state.record(result, head: before)
        if readHead() != before {
            state.invalidate()
            throw SyncError.ingestIncomplete
        }
        if result.manifestDamaged { throw ManifestError.damaged }
        if result.storeUnreadable { throw SyncError.storeUnreadable(result.warnings) }
        if result.ingestIncomplete { throw SyncError.ingestIncomplete }
        return result
    }
}
