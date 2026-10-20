import Foundation
import SwiftData

/// A refused skill field stays local until disk acknowledges its current value.
/// The window owns this object; the ingest state receives only its plain projection.
/// CategoryStore edits use local undo instead. Retirement still projects its category memberships.
final class ManifestRefusedEdit {
    private typealias Field = RefusedManifestProjection.Field
    let id = UUID()
    private var registration: StoreIngestState?
    private var projection: RefusedManifestProjection {
        RefusedManifestProjection(fields: fields ?? [.change(original)], cachedLocal: cachedLocal)
    }

    deinit { registration?.forgetRefused(id) }

    func retain() {
        registration = StoreIngestState.shared(for: context.container)
        updateRegistration()
    }

    private func updateRegistration() {
        registration?.retainRefused(projection, id: id)
    }
    let context: ModelContext
    private let original: ManifestChange
    private var fields: [Field]?
    private var cachedLocal: ManifestSnapshot?

    init(_ change: ManifestChange, context: ModelContext) {
        self.context = context
        original = change
        switch change {
        case .skillMetadata(let slug, let tags, let scope, let cursor, let origin):
            fields = []
            if tags != nil { fields?.append(.change(.skillMetadata(slug, tags, nil))) }
            if scope != nil { fields?.append(.change(.skillMetadata(slug, nil, scope))) }
            if let cursor { fields?.append(.change(.skillMetadata(slug, nil, nil, cursor: .some(cursor)))) }
            if let origin { fields?.append(.change(.skillMetadata(slug, nil, nil, origin: origin))) }
        case .retireSkill: break
        default: fields = [.change(change)]
        }
    }

    func cache(local: ManifestSnapshot?) {
        if let local { cachedLocal = local }
        updateRegistration()
    }

    /// Keep the last readable local snapshot current while a later projection read is unavailable.
    func observe(_ change: ManifestChange) {
        if var local = cachedLocal {
            change.apply(to: &local)
            cachedLocal = local
            updateRegistration()
        }
    }

    func suppliesTarget(for edit: ManifestRefusedEdit) -> Bool {
        switch (original, edit.original) {
        case (.createSkill(let skill), .skillMetadata(let slug, _, _, _, _)): return skill.slug == slug
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
            projection.project(field, onto: &probe)
            if probe != durable { remaining.append(field) }
        }
        fields = remaining
        updateRegistration()
        return !remaining.isEmpty
    }

    func project(onto displayed: inout ManifestSnapshot) {
        projection.project(onto: &displayed)
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

    private func retirementFields(durable: ManifestSnapshot) -> [Field] {
        guard case .retireSkill(let slug) = original else { return [] }
        return durable.categories.filter { $0.skillSlugs.contains(slug) }.map {
            .change(.categorySkill($0.name, slug, false))
        } + durable.deployIntents.filter { $0.skillSlug == slug }.map { .intent($0) }
    }

}
