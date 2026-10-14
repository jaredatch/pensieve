import Foundation
import SwiftData

/// Presentation only: a refused skill field stays local until disk acknowledges its current value.
/// CategoryStore edits use local undo instead. Retirement still projects its category memberships.
final class ManifestRefusedEdit {
    private enum Field {
        case change(ManifestChange)
        case intent(DeployIntentRecord)
    }
    let context: ModelContext
    private let original: ManifestChange
    private var fields: [Field]?
    private var cachedLocal: ManifestSnapshot?

    init(_ change: ManifestChange, context: ModelContext) {
        self.context = context
        original = change
        switch change {
        case .skillMetadata(let slug, let tags, let scope):
            fields = []
            if tags != nil { fields?.append(.change(.skillMetadata(slug, tags, nil))) }
            if scope != nil { fields?.append(.change(.skillMetadata(slug, nil, scope))) }
        case .retireSkill: break
        default: fields = [.change(change)]
        }
    }

    func cache(local: ManifestSnapshot?) {
        if let local { cachedLocal = local }
    }

    /// Keep the last readable local snapshot current while a later projection read is unavailable.
    func observe(_ change: ManifestChange) {
        if var local = cachedLocal {
            change.apply(to: &local)
            cachedLocal = local
        }
    }

    func suppliesTarget(for edit: ManifestRefusedEdit) -> Bool {
        switch (original, edit.original) {
        case (.createSkill(let skill), .skillMetadata(let slug, _, _)): return skill.slug == slug
        default: return false
        }
    }

    func refresh(durable: ManifestSnapshot) -> Bool {
        if fields == nil { fields = retirementFields(durable: durable) }
        return acknowledge(durable: durable)
    }

    /// Publication can acknowledge cached fields without another main-context read.
    func acknowledge(durable: ManifestSnapshot) -> Bool {
        var remaining: [Field] = []
        for field in fields ?? [] {
            var probe = durable
            project(field, onto: &probe)
            if probe != durable { remaining.append(field) }
        }
        fields = remaining
        return !remaining.isEmpty
    }

    func project(onto displayed: inout ManifestSnapshot) {
        for field in fields ?? [] { project(field, onto: &displayed) }
    }

    /// A category deleted before retirement may be restored by undo afterward.
    func preserveRetirement(in categories: [Category]) {
        guard case .retireSkill(let slug) = original else { return }
        for category in categories {
            if let fields, !fields.contains(where: { field in
                guard case .change(.categorySkill(let name, let target, _)) = field else { return false }
                return name == category.name && target == slug
            }) { continue }
            // Current local values still win. An acknowledged field or a later reassignment
            // must not be retired again just because another retirement field remains refused.
            if cachedLocal?.categories.first(where: { $0.name == category.name })?.skillSlugs.contains(slug) == true { continue }
            category.skillSlugs.removeAll { $0 == slug }
        }
    }

    private func project(_ field: Field, onto snapshot: inout ManifestSnapshot) {
        if let cachedLocal {
            apply(field, local: cachedLocal, onto: &snapshot)
        } else if case .change(let change) = field { change.apply(to: &snapshot) }
    }

    private func retirementFields(durable: ManifestSnapshot) -> [Field] {
        guard case .retireSkill(let slug) = original else { return [] }
        return durable.categories.filter { $0.skillSlugs.contains(slug) }.map {
            .change(.categorySkill($0.name, slug, false))
        } + durable.deployIntents.filter { $0.skillSlug == slug }.map { .intent($0) }
    }

    private func apply(_ field: Field, local: ManifestSnapshot, onto snapshot: inout ManifestSnapshot) {
        switch field {
        case .intent(let intent):
            if local.deployIntents.contains(intent) {
                if !snapshot.deployIntents.contains(intent) { snapshot.deployIntents.append(intent) }
            } else { snapshot.deployIntents.removeAll { $0 == intent } }
        case .change(let change):
            if case .categorySkill(let name, let slug, _) = change {
                guard let record = local.categories.first(where: { $0.name == name }) else { return }
                let update = ManifestChange.categorySkill(name, slug, record.skillSlugs.contains(slug))
                if !update.apply(to: &snapshot) { ManifestChange.createCategory(record).apply(to: &snapshot) }
            } else { applySkill(change, local: local, onto: &snapshot) }
        }
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
