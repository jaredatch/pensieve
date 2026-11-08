import Foundation
import SwiftData

/// A refused skill field stays local until disk acknowledges its current value.
/// The window owns this object; the ingest state receives only its plain projection.
/// CategoryStore edits use local undo instead. Retirement uses a raw fallback until readable
/// disk supplies its membership and intent fields, then acknowledges those fields independently.
final class ManifestRefusedEdit {
    private typealias Field = RefusedManifestProjection.Field
    let id = UUID()
    private var registration: StoreIngestState?
    private var projection: RefusedManifestProjection {
        RefusedManifestProjection(fields: fields ?? [.change(original)], cachedLocal: cachedLocal,
                                  collision: collision, intentMove: intentMove, categoryRenames: categoryRenames)
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
    private let order: Int
    private let original: ManifestChange
    private(set) var collision: SkillOverlay?
    private var collisionProbePending = false
    var isCollisionHeld: Bool { collision != nil || collisionProbePending }

    /// A failed launch probe cannot safely admit a rename or delete of the unknown peer's record.
    func holdUntilReadableProbe() { collisionProbePending = true }
    private var heldBy: SkillOverlay?
    let intentMove: ManifestLocalIntentMove?

    var createdSkill: SkillOverlay? {
        if case .createSkill(let skill) = original { return skill }
        return nil
    }

    func targets(_ slug: String) -> Bool {
        switch original {
        case .createSkill(let skill): return skill.slug == slug
        case .skillMetadata(let target, _, _): return target == slug
        default: return false
        }
    }

    func hold(with create: ManifestRefusedEdit) { heldBy = create.createdSkill }

    private var fields: [Field]?
    private var cachedLocal: ManifestSnapshot?
    private var categoryRenames: [RefusedManifestProjection.CategoryRename] = []

    init(_ change: ManifestChange, context: ModelContext, order: Int = 0, intentMove: ManifestLocalIntentMove? = nil) {
        self.intentMove = intentMove
        self.context = context
        self.order = order
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
        updateRegistration()
    }

    /// Keep the last readable local snapshot current while a later projection read is unavailable.
    func observe(_ change: ManifestChange) {
        if case .retireSkill = original, case .renameCategory(let old, let new) = change {
            categoryRenames.append(.init(old: old, new: new))
        }
        if var local = cachedLocal {
            change.apply(to: &local)
            cachedLocal = local
        }
        updateRegistration()
    }

    /// A retirement can still be waiting for its first attempt when the category is renamed.
    func observePending(_ change: ManifestChange) {
        if case .retireSkill = original { observe(change) }
    }

    func suppliesTarget(for edit: ManifestRefusedEdit) -> Bool {
        switch (original, edit.original) {
        case (.createSkill(let skill), .skillMetadata(let slug, _, _)): return skill.slug == slug
        default: return false
        }
    }

    /// Publication can acknowledge cached fields without another main-context read.
    func acknowledge(durable: ManifestSnapshot) -> Bool {
        if let identity = createdSkill ?? heldBy {
            collisionProbePending = false
            let disk = durable.skills.first { $0.slug == identity.slug }
            collision = disk.flatMap { ManifestService.sameCreation(identity, $0) ? nil : $0 }
            if createdSkill != nil {
                let unsaved = disk.map { !ManifestService.sameCreation(identity, $0) } ?? true
                if !unsaved { fields = [] }
                updateRegistration()
                return unsaved
            }
            if collision != nil {
                updateRegistration()
                return true
            }
        }
        if fields == nil { fields = retirementFields(durable: durable) }
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

    func project(onto displayed: inout ManifestSnapshot, knownCreates: [SkillOverlay] = [],
                 local: ManifestSnapshot? = nil, durable: ManifestSnapshot? = nil) {
        projection.project(onto: &displayed, keepingLocalCreates: true, knownCreates: knownCreates,
                           local: local, durable: durable)
    }

    /// Decide from capture order, never from membership copied back into the window by undo.
    func preserveRetirement(in categories: [Category], undoing undos: [(order: Int, edit: CategorySaveEdit)]) {
        guard case .retireSkill(let slug) = original else { return }
        for undo in undos {
            if case .renameCategory(let old, let new) = undo.edit.change,
               let index = categoryRenames.lastIndex(of: .init(old: old, new: new)) {
                categoryRenames.remove(at: index)
            }
            if let inverse = undo.edit.inverse, var local = cachedLocal {
                inverse.apply(to: &local)
                cachedLocal = local
            }
        }
        for undo in undos {
            guard undo.order < order, undo.edit.restoredSkillSlugs.contains(slug),
                  let category = categories.first(where: { $0.id == undo.edit.id }) else { continue }
            if let fields, !fields.contains(where: { field in
                guard case .change(.categorySkill(let name, let target, _)) = field else { return false }
                return projection.windowCategoryName(for: name) == category.name && target == slug
            }) { continue }
            category.skillSlugs.removeAll { $0 == slug }
            if var local = cachedLocal {
                ManifestChange.categorySkill(category.name, slug, false).apply(to: &local)
                cachedLocal = local
            }
        }
        updateRegistration()
    }

    private func retirementFields(durable: ManifestSnapshot) -> [Field] {
        guard case .retireSkill(let slug) = original else { return [] }
        return durable.categories.filter { $0.skillSlugs.contains(slug) }.map {
            .change(.categorySkill($0.name, slug, false))
        } + durable.deployIntents.filter { $0.skillSlug == slug }.map { .intent($0) }
    }

}
