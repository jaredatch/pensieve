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
    var windowID: UUID { window.id }

    func save(in context: ModelContext) throws { try window.save(in: context) }

    init(category: Category, context: ModelContext, change: ManifestChange, existed: Bool = true) {
        window = CategorySaveWindow(context: context)
        id = category.id
        createdAt = category.createdAt
        before = existed ? CategoryRecord(category) : nil
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

    /// Compare the edited result with saved rules, or with the window for a superseded notice.
    /// Healing publication is tracked permanently by the queue.
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

    enum Outcome { case undone, saved, restored, removed }

    /// A saved rebuild in any context of our container supersedes this inverse. Its rows can
    /// reuse our UUID by name. Without a rebuild, only our own delete can insert a missing row.
    func restore(in context: ModelContext) throws -> Outcome {
        let categories = try context.fetch(FetchDescriptor<Category>())
        if wasRebuilt {
            // Dependents have already been restored. This classifies the notice only; a rebuild
            // supersedes the inverse whether it published our result or restored an earlier rule.
            let displayed = ManifestSnapshot(schemaVersion: ManifestService.currentSchemaVersion,
                categories: categories.map(CategoryRecord.init), projects: [], skills: [])
            if isSaved(in: displayed) { return .saved }
            return categories.contains { $0.name == name } ? .restored : .removed
        }
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

/// Order the local edit's save against the rebuild's category fetch, across shared contexts.
/// Only successful authoritative rebuilds announce their read; queue previews never announce.
final class CategorySaveWindow {
    struct ReadReceipt {
        let containerID: ObjectIdentifier
        let order: UInt64
        var retainedWindows: Set<UUID> = []
    }
    let id = UUID()
    private static let rebuilt = Notification.Name("Pensieve.categoryWindowRebuilt")
    private static let ordering = NSLock()
    private static var order: UInt64 = 0
    private var observer: NSObjectProtocol?
    private var savedAt: UInt64?
    private var rebuilt = false
    var wasRebuilt: Bool {
        Self.ordering.lock()
        defer { Self.ordering.unlock() }
        return rebuilt
    }

    init(context: ModelContext) {
        let containerID = ObjectIdentifier(context.container)
        observer = NotificationCenter.default.addObserver(
            forName: Self.rebuilt, object: nil, queue: nil
        ) { [weak self] notification in
            guard let read = notification.object as? ReadReceipt,
                  read.containerID == containerID else { return }
            self?.recordRebuild(read)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func save(in context: ModelContext) throws {
        Self.ordering.lock()
        defer { Self.ordering.unlock() }
        try context.save()
        Self.order += 1
        savedAt = Self.order
    }

    static func fetchCategories(in context: ModelContext) throws -> (rows: [Category], receipt: ReadReceipt) {
        ordering.lock()
        defer { ordering.unlock() }
        let rows = try context.fetch(FetchDescriptor<Category>())
        order += 1
        return (rows, ReadReceipt(containerID: ObjectIdentifier(context.container), order: order))
    }

    private func recordRebuild(_ read: ReadReceipt) {
        Self.ordering.lock()
        defer { Self.ordering.unlock() }
        if let savedAt, savedAt < read.order { rebuilt = !read.retainedWindows.contains(id) }
    }

    static func didRebuild(_ read: ReadReceipt) {
        NotificationCenter.default.post(name: rebuilt, object: read)
    }
}
