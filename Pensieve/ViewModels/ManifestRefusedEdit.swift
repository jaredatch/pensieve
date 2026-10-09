import Foundation
import SwiftData

/// Presentation only: a refused field stays local until disk acknowledges its current value.
/// Read the live context so later edits supersede the refused value without replaying stale data.
final class ManifestRefusedEdit {
    private enum Field {
        case change(ManifestChange)
        case intent(DeployIntentRecord)
    }
    private let context: ModelContext
    private let manifest: ManifestSnapshotting
    private let original: ManifestChange
    private let categoryID: UUID?
    private var fields: [Field]?

    init(_ change: ManifestChange, context: ModelContext, manifest: ManifestSnapshotting) {
        self.context = context
        self.manifest = manifest
        self.original = change
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        categoryID = categories.first { $0.name == Self.categoryName(change) }?.id
        switch change {
        case .skillMetadata(let slug, let tags, let scope):
            fields = []
            if tags != nil { fields?.append(.change(.skillMetadata(slug, tags, nil))) }
            if scope != nil { fields?.append(.change(.skillMetadata(slug, nil, scope))) }
        case .retireSkill: break
        default: fields = [.change(change)]
        }
    }

    func project(durable: ManifestSnapshot, onto displayed: inout ManifestSnapshot) throws -> Bool {
        let local = try manifest.snapshot(from: context)
        let categories = try context.fetch(FetchDescriptor<Category>())
        let name = categories.first { $0.id == categoryID }?.name
        if fields == nil { fields = retirementFields(durable: durable) }
        var remaining: [Field] = []
        for field in fields ?? [] {
            // Compare each field with disk, independently of the other presentation overlays.
            var probe = durable
            apply(field, local: local, name: name, onto: &probe)
            if probe != durable {
                remaining.append(field)
                apply(field, local: local, name: name, onto: &displayed)
            }
        }
        fields = remaining
        return !remaining.isEmpty
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
