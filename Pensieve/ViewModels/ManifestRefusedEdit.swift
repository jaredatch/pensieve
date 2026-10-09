import Foundation
import SwiftData

/// Presentation only: a refused field stays local until disk acknowledges its current value.
/// Read the live context so later edits supersede the refused value without replaying stale data.
final class ManifestRefusedEdit {
    private enum Field {
        case change(ManifestChange)
        case intent(DeployIntentRecord)
    }
    let context: ModelContext
    private let original: ManifestChange
    private let categoryID: UUID?
    private var fields: [Field]?
    private var cachedLocal: ManifestSnapshot?
    private var cachedName: String?
    private var initialCategory: CategoryRecord?

    init(_ change: ManifestChange, context: ModelContext) {
        self.context = context
        self.original = change
        if let name = Self.categoryName(change) {
            categoryID = (try? context.fetch(FetchDescriptor<Category>()))?.first { $0.name == name }?.id
            cachedName = name
        } else { categoryID = nil }
        switch change {
        case .skillMetadata(let slug, let tags, let scope):
            fields = []
            if tags != nil { fields?.append(.change(.skillMetadata(slug, tags, nil))) }
            if scope != nil { fields?.append(.change(.skillMetadata(slug, nil, scope))) }
        case .retireSkill: break
        default: fields = [.change(change)]
        }
    }

    func remember(durable: ManifestSnapshot) {
        if case .deleteCategory(let name) = original {
            initialCategory = durable.categories.first { $0.name == name }
        }
    }

    func cache(local: ManifestSnapshot?, categories: [Category]?) {
        if let local { cachedLocal = local }
        if let categories, let categoryID { cachedName = categories.first { $0.id == categoryID }?.name }
    }

    /// Keep the last readable local snapshot current while a later projection read is unavailable.
    func observe(_ change: ManifestChange) {
        if var local = cachedLocal {
            change.apply(to: &local)
            cachedLocal = local
        }
        if case .renameCategory(let old, let new) = change, cachedName == old { cachedName = new }
    }

    func suppliesTarget(for edit: ManifestRefusedEdit) -> Bool {
        if let categoryID, categoryID == edit.categoryID { return true }
        switch (original, edit.original) {
        case (.createSkill(let skill), .skillMetadata(let slug, _, _)): return skill.slug == slug
        default: return false
        }
    }

    func suppliesCategory(in durable: ManifestSnapshot) -> UUID? {
        switch original {
        case .createCategory: return categoryID
        case .renameCategory(let old, _):
            return durable.categories.contains { $0.name == old } ? categoryID : nil
        default: return nil
        }
    }

    func project(durable: ManifestSnapshot, supplied: Set<UUID>, onto displayed: inout ManifestSnapshot) -> Bool {
        guard hasTarget(in: durable, supplied: supplied) else { return false }
        if fields == nil { fields = retirementFields(durable: durable) }
        var remaining: [Field] = []
        for field in fields ?? [] {
            var probe = durable
            project(field, onto: &probe)
            if probe != durable {
                remaining.append(field)
                project(field, onto: &displayed)
            }
        }
        fields = remaining
        return !remaining.isEmpty
    }

    private func hasTarget(in durable: ManifestSnapshot, supplied: Set<UUID>) -> Bool {
        if let target = Self.categoryName(original) {
            switch original {
            case .createCategory: break
            case .deleteCategory(let name):
                guard let current = durable.categories.first(where: { $0.name == name }) else { return false }
                if let initialCategory, current != initialCategory { return false }
                if initialCategory == nil { initialCategory = current }
            case .renameCategory(let old, _):
                guard durable.categories.contains(where: { $0.name == old || $0.name == cachedName })
                    || categoryID.map(supplied.contains) == true else { return false }
            default:
                guard durable.categories.contains(where: { $0.name == target || $0.name == cachedName })
                    || categoryID.map(supplied.contains) == true else { return false }
            }
        }
        return true
    }

    private func project(_ field: Field, onto snapshot: inout ManifestSnapshot) {
        if let cachedLocal {
            apply(field, local: cachedLocal, name: cachedName, onto: &snapshot)
        } else if case .change(let change) = field { change.apply(to: &snapshot) }
    }

    private static func categoryName(_ change: ManifestChange) -> String? {
        switch change {
        case .createCategory(let record): record.name
        case .renameCategory(_, let name), .deleteCategory(let name),
             .categoryProject(let name, _, _), .categorySkill(let name, _, _): name
        default: nil
        }
    }

    private func retirementFields(durable: ManifestSnapshot) -> [Field] {
        guard case .retireSkill(let slug) = original else { return [] }
        return durable.categories.filter { $0.skillSlugs.contains(slug) }.map {
            .change(.categorySkill($0.name, slug, false))
        } + durable.deployIntents.filter { $0.skillSlug == slug }.map { .intent($0) }
    }

    private func apply(_ field: Field, local: ManifestSnapshot, name: String?, onto snapshot: inout ManifestSnapshot) {
        switch field {
        case .intent(let intent):
            if local.deployIntents.contains(intent) {
                if !snapshot.deployIntents.contains(intent) { snapshot.deployIntents.append(intent) }
            } else { snapshot.deployIntents.removeAll { $0 == intent } }
        case .change(let change):
            if Self.categoryName(change) != nil {
                applyCategory(change, local: local, name: name, onto: &snapshot)
            } else { applySkill(change, local: local, onto: &snapshot) }
        }
    }

    private func applyCategory(_ change: ManifestChange, local: ManifestSnapshot,
                               name: String?, onto snapshot: inout ManifestSnapshot) {
        let target = name ?? (categoryID == nil ? Self.categoryName(change) : nil)
        let record = local.categories.first { $0.name == target }
        switch change {
        case .deleteCategory(let deleted):
            if !local.categories.contains(where: { $0.name == deleted }) {
                ManifestChange.deleteCategory(deleted).apply(to: &snapshot)
            }
        case .renameCategory(let old, _):
            guard let record else { ManifestChange.deleteCategory(old).apply(to: &snapshot); return }
            if !ManifestChange.renameCategory(old, record.name).apply(to: &snapshot) {
                ManifestChange.createCategory(record).apply(to: &snapshot)
            }
        case .createCategory:
            if let record { ManifestChange.createCategory(record).apply(to: &snapshot) }
        default:
            guard let record else { return }
            applyMembership(change, record: record, onto: &snapshot)
        }
    }

    private func applyMembership(_ change: ManifestChange, record: CategoryRecord, onto snapshot: inout ManifestSnapshot) {
        let update: ManifestChange
        switch change {
        case .categoryProject(_, let key, _):
            update = .categoryProject(record.name, key, record.projectKeys.contains(key))
        case .categorySkill(_, let slug, _):
            update = .categorySkill(record.name, slug, record.skillSlugs.contains(slug))
        default: return
        }
        if !update.apply(to: &snapshot) { ManifestChange.createCategory(record).apply(to: &snapshot) }
    }

    private func applySkill(_ change: ManifestChange, local: ManifestSnapshot, onto snapshot: inout ManifestSnapshot) {
        switch change {
        case .createSkill(let original):
            if let current = local.skills.first(where: { $0.slug == original.slug }) {
                ManifestChange.createSkill(current).apply(to: &snapshot)
            }
        case .deleteSkill(let slug):
            if !local.skills.contains(where: { $0.slug == slug }) { ManifestChange.deleteSkill(slug).apply(to: &snapshot) }
        case .skillMetadata(let slug, let tags, let scope):
            guard let current = local.skills.first(where: { $0.slug == slug }) else { return }
            let update = ManifestChange.skillMetadata(slug, tags == nil ? nil : current.tags, scope == nil ? nil : current.scope)
            if !update.apply(to: &snapshot) { ManifestChange.createSkill(current).apply(to: &snapshot) }
        default: break
        }
    }
}
