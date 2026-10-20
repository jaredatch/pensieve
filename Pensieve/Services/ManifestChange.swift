import Foundation

/// An edit, rather than a replacement tree. Apply only after acquiring sync.lock and reading disk.
enum ManifestChange {
    case createCategory(CategoryRecord)
    case renameCategory(String, String)
    case deleteCategory(String)
    case categoryProject(String, String, Bool)
    case categorySkill(String, String, Bool)
    case createSkill(SkillOverlay)
    case skillMetadata(String, [String]?, SkillScope?)
    case deleteSkill(String)
    case retireSkill(String)

    var isDeletion: Bool {
        switch self {
        case .deleteCategory, .deleteSkill: true
        default: false
        }
    }

    /// Validate before durable publication and before projecting pending edits into the window.
    /// A conflicting pending rename is refused and undone before its projection is accepted.
    func validate(in snapshot: ManifestSnapshot) throws {
        guard case .renameCategory(let old, let new) = self,
              let target = snapshot.categories.firstIndex(where: { $0.name == old }) else { return }
        let others = snapshot.categories.indices.filter { $0 != target }.map { snapshot.categories[$0].name }
        if let taken = CategoryName.takenName(new, among: others) { throw CategoryNameError.taken(taken) }
    }

    /// False means the target is absent. The queue still publishes idempotent deletions.
    @discardableResult
    func apply(to snapshot: inout ManifestSnapshot) -> Bool {
        switch self {
        case .createCategory, .renameCategory, .deleteCategory, .categoryProject, .categorySkill:
            return applyCategory(to: &snapshot)
        default: return applySkill(to: &snapshot)
        }
    }

    private func applyCategory(to snapshot: inout ManifestSnapshot) -> Bool {
        switch self {
        case .createCategory(let record):
            if !snapshot.categories.contains(where: { $0.name == record.name }) { snapshot.categories.append(record) }
        case .renameCategory(let old, let new):
            guard let index = snapshot.categories.firstIndex(where: { $0.name == old }) else { return false }
            snapshot.categories[index].name = new
        case .deleteCategory(let name):
            let count = snapshot.categories.count
            snapshot.categories.removeAll { $0.name == name }
            return snapshot.categories.count != count
        case .categoryProject(let name, let key, let member):
            guard let index = snapshot.categories.firstIndex(where: { $0.name == name }) else { return false }
            Self.set(key, present: member, in: &snapshot.categories[index].projectKeys)
        case .categorySkill(let name, let slug, let member):
            guard let index = snapshot.categories.firstIndex(where: { $0.name == name }) else { return false }
            Self.set(slug, present: member, in: &snapshot.categories[index].skillSlugs)
        default: return false
        }
        return true
    }

    private func applySkill(to snapshot: inout ManifestSnapshot) -> Bool {
        switch self {
        case .createSkill(let overlay):
            if let index = snapshot.skills.firstIndex(where: { $0.slug == overlay.slug }) {
                snapshot.skills[index] = overlay
            } else { snapshot.skills.append(overlay) }
        case .skillMetadata(let slug, let tags, let scope):
            return updateMetadata(slug, tags: tags, scope: scope, in: &snapshot)
        case .deleteSkill(let slug):
            let count = snapshot.skills.count
            snapshot.skills.removeAll { $0.slug == slug }
            return snapshot.skills.count != count
        case .retireSkill(let slug):
            snapshot.deployIntents.removeAll { $0.skillSlug == slug }
            for index in snapshot.categories.indices { snapshot.categories[index].skillSlugs.removeAll { $0 == slug } }
        default: return false
        }
        return true
    }

    private func updateMetadata(_ slug: String, tags: [String]?, scope: SkillScope?,
                                in snapshot: inout ManifestSnapshot) -> Bool {
        guard let index = snapshot.skills.firstIndex(where: { $0.slug == slug }) else { return false }
        if let tags { snapshot.skills[index].tags = tags }
        if let scope { snapshot.skills[index].scope = scope }
        return true
    }

    private static func set(_ value: String, present: Bool, in values: inout [String]) {
        if present {
            if !values.contains(value) { values.append(value) }
        } else { values.removeAll { $0 == value } }
    }
}

/// Immutable, context-free values for retaining refused fields across worker rebuilds.
/// Only requested fields project, and newer queued edits apply after these values.
struct RefusedManifestProjection {
    enum Field {
        case change(ManifestChange)
        case intent(DeployIntentRecord)
    }
    let fields: [Field]
    let cachedLocal: ManifestSnapshot?

    func project(onto snapshot: inout ManifestSnapshot) {
        for field in fields { project(field, onto: &snapshot) }
    }

    func project(_ field: Field, onto snapshot: inout ManifestSnapshot) {
        if case .change(let change) = field {
            do { try change.validate(in: snapshot) } catch { return }
            if case .createSkill(let original) = change {
                projectCreate(original, onto: &snapshot)
                return
            }
        }
        if let cachedLocal {
            apply(field, local: cachedLocal, onto: &snapshot)
        } else {
            switch field {
            case .change(let change): change.apply(to: &snapshot)
            case .intent(let intent): snapshot.deployIntents.removeAll { $0 == intent }
            }
        }
    }

    private func projectCreate(_ original: SkillOverlay, onto snapshot: inout ManifestSnapshot) {
        let current: SkillOverlay
        if let cachedLocal {
            guard let local = cachedLocal.skills.first(where: { $0.slug == original.slug }) else { return }
            current = local
        } else { current = original }
        // Compare stored values, including timestamp precision and set order, not slug presence.
        if let durable = snapshot.skills.first(where: { $0.slug == current.slug }),
           ManifestService.serializeSkillOverlay(durable) == ManifestService.serializeSkillOverlay(current) { return }
        ManifestChange.createSkill(current).apply(to: &snapshot)
    }

    private func apply(_ field: Field, local: ManifestSnapshot, onto snapshot: inout ManifestSnapshot) {
        switch field {
        case .intent(let intent):
            if local.deployIntents.contains(intent) {
                if !snapshot.deployIntents.contains(intent) { snapshot.deployIntents.append(intent) }
            } else { snapshot.deployIntents.removeAll { $0 == intent } }
        case .change(let change):
            if case .categorySkill(let name, let slug, _) = change {
                guard let record = local.categories.first(where: { $0.name == name }) else {
                    // A newly read retirement field can name a category the window has never seen.
                    if case .categorySkill(_, _, false) = change { change.apply(to: &snapshot) }
                    return
                }
                let update = ManifestChange.categorySkill(name, slug, record.skillSlugs.contains(slug))
                if !update.apply(to: &snapshot) { ManifestChange.createCategory(record).apply(to: &snapshot) }
            } else { applySkill(change, local: local, onto: &snapshot) }
        }
    }

    private func applySkill(_ change: ManifestChange, local: ManifestSnapshot, onto snapshot: inout ManifestSnapshot) {
        switch change {
        case .deleteSkill(let slug):
            if !local.skills.contains(where: { $0.slug == slug }) { ManifestChange.deleteSkill(slug).apply(to: &snapshot) }
        case .skillMetadata(let slug, let tags, let scope):
            guard let current = local.skills.first(where: { $0.slug == slug }) else { return }
            let update = ManifestChange.skillMetadata(slug, tags == nil ? nil : current.tags, scope == nil ? nil : current.scope)
            if !update.apply(to: &snapshot) { ManifestChange.createSkill(current).apply(to: &snapshot) }
        default: change.apply(to: &snapshot)
        }
    }
}
