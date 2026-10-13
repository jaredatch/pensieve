import Foundation
import SwiftData

/// The local identity and rule before a category mutation. Undo changes only the edited field;
/// deleting a row needs the complete rule and creation date to restore that same identity.
struct CategorySaveEdit {
    let id: UUID
    let createdAt: Date
    let before: CategoryRecord?
    let after: CategoryRecord?
    let change: ManifestChange
    private let window: CategorySaveWindow

    var wasRebuilt: Bool { window.wasRebuilt }

    init(category: Category, context: ModelContext, change: ManifestChange, existed: Bool = true) {
        window = CategorySaveWindow(context: context)
        id = category.id
        createdAt = category.createdAt
        before = existed ? CategoryRecord(name: category.name, projectKeys: category.projectKeys,
                                          skillSlugs: category.skillSlugs) : nil
        self.change = change
        var snapshot = ManifestSnapshot(schemaVersion: ManifestService.currentSchemaVersion,
                                        categories: before.map { [$0] } ?? [], projects: [], skills: [])
        change.apply(to: &snapshot)
        after = snapshot.categories.first
    }

    var name: String { before?.name ?? after?.name ?? "" }
    var claimedName: String? {
        switch change {
        case .createCategory, .renameCategory: after?.name
        default: nil
        }
    }
    var restoredName: String? {
        switch change {
        case .renameCategory, .deleteCategory: before?.name
        default: nil
        }
    }

    /// Evidence from this item's own attempt. Healing publication is tracked by the queue.
    func isSaved(in durable: ManifestSnapshot) -> Bool {
        let final = after
        if final == nil {
            return !durable.categories.contains { $0.name == before?.name }
        }
        guard let final, let saved = durable.categories.first(where: { $0.name == final.name }) else { return false }
        switch change {
        case .categorySkill(_, let slug, _):
            return saved.skillSlugs.contains(slug) == final.skillSlugs.contains(slug)
        case .categoryProject(_, let key, _):
            return saved.projectKeys.contains(key) == final.projectKeys.contains(key)
        case .renameCategory(let old, _):
            return old == final.name || !durable.categories.contains { $0.name == old }
        case .createCategory:
            return Set(saved.projectKeys) == Set(final.projectKeys) && Set(saved.skillSlugs) == Set(final.skillSlugs)
        default: return false
        }
    }

    enum Restoration { case undone, restored, removed }

    /// A saved rebuild in any context of our container supersedes this inverse. Its rows can
    /// reuse our UUID by name. Without a rebuild, only our own delete can insert a missing row.
    func restore(in context: ModelContext) throws -> Restoration {
        let categories = try context.fetch(FetchDescriptor<Category>())
        if wasRebuilt { return categories.contains { $0.name == name } ? .restored : .removed }
        let existing = categories.first { $0.id == id }
        guard let before else {
            guard let existing else { return .removed }
            context.delete(existing)
            return .undone
        }
        let row: Category
        if let existing { row = existing } else {
            guard case .deleteCategory = change else { return .removed }
            row = Category(name: before.name)
            row.id = id
            row.createdAt = createdAt
            row.projectKeys = before.projectKeys
            row.skillSlugs = before.skillSlugs
            context.insert(row)
        }
        restoreFields(row, from: before)
        return .undone
    }

    private func restoreFields(_ row: Category, from before: CategoryRecord) {
        switch change {
        case .renameCategory: row.name = before.name
        case .categorySkill(_, let slug, _):
            row.skillSlugs.removeAll { $0 == slug }
            if before.skillSlugs.contains(slug) { row.skillSlugs.append(slug) }
        case .categoryProject(_, let key, _):
            row.projectKeys.removeAll { $0 == key }
            if before.projectKeys.contains(key) { row.projectKeys.append(key) }
        default: break
        }
    }
}

/// Each pending edit observes saved authoritative rebuilds across its shared container. The
/// rebuild may run off the main actor, so its observation is protected independently of SwiftData.
/// The queue's unsaved preview and acceptance of pending overlays send no rebuild notification.
final class CategorySaveWindow {
    private static let rebuilt = Notification.Name("Pensieve.categoryWindowRebuilt")
    private let lock = NSLock()
    private var observer: NSObjectProtocol?
    private var rebuilt = false
    var wasRebuilt: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rebuilt
    }

    init(context: ModelContext) {
        let containerID = ObjectIdentifier(context.container)
        observer = NotificationCenter.default.addObserver(
            forName: Self.rebuilt, object: nil, queue: nil
        ) { [weak self] notification in
            guard let container = notification.object as? ModelContainer,
                  ObjectIdentifier(container) == containerID else { return }
            self?.recordRebuild()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func recordRebuild() {
        lock.lock()
        defer { lock.unlock() }
        rebuilt = true
    }

    static func didRebuild(_ context: ModelContext) {
        NotificationCenter.default.post(name: rebuilt, object: context.container)
    }
}
