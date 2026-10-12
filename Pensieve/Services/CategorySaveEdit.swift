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

    init(category: Category, change: ManifestChange, existed: Bool = true) {
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

    /// A heal can publish later queued edits too. Compare the edited field at its latest queued
    /// value and name, rather than mistaking an intermediate rename for an unsaved edit.
    func isSaved(in durable: ManifestSnapshot, following: [CategorySaveEdit], receipt: ManifestSnapshot?) -> Bool {
        // A heal can delete a row and create a different local identity under the same name.
        // The published category tree confirms both edits, even though the name still exists.
        if let receipt, receipt.categories.count == durable.categories.count,
           receipt.categories.allSatisfy({ published in
               durable.categories.contains {
                   $0.name == published.name && Set($0.projectKeys) == Set(published.projectKeys)
                       && Set($0.skillSlugs) == Set(published.skillSlugs)
               }
           }) { return true }
        let sameCategory = following.filter { $0.id == id }
        let final = sameCategory.isEmpty ? after : sameCategory.last?.after
        let names = [before?.name, after?.name] + sameCategory.flatMap { [$0.before?.name, $0.after?.name] }
        if final == nil {
            return !durable.categories.contains { names.contains($0.name) }
        }
        guard let final, let saved = durable.categories.first(where: { $0.name == final.name }) else { return false }
        switch change {
        case .categorySkill(_, let slug, _):
            return saved.skillSlugs.contains(slug) == final.skillSlugs.contains(slug)
        case .categoryProject(_, let key, _):
            return saved.projectKeys.contains(key) == final.projectKeys.contains(key)
        case .renameCategory(let old, _):
            // The target name can belong to a different category pulled from another Mac.
            // A saved rename also removed the original name.
            return old == final.name || !durable.categories.contains { $0.name == old }
        case .createCategory:
            return Set(saved.projectKeys) == Set(final.projectKeys) && Set(saved.skillSlugs) == Set(final.skillSlugs)
        default: return false
        }
    }

    /// False means sync removed the target; only undoing our own delete can insert a missing row.
    func restore(in context: ModelContext) throws -> Bool {
        let existing = try context.fetch(FetchDescriptor<Category>()).first { $0.id == id }
        guard let before else {
            if let existing { context.delete(existing) }
            return true
        }
        let row: Category
        if let existing { row = existing } else {
            guard case .deleteCategory = change else { return false }
            row = Category(name: before.name)
            row.id = id
            row.createdAt = createdAt
            row.projectKeys = before.projectKeys
            row.skillSlugs = before.skillSlugs
            context.insert(row)
        }
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
        return true
    }
}
