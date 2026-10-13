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

    /// Validate only the durable publication. Pending window projections may temporarily claim
    /// a name a peer has since taken; the queue must reach that edit's turn to refuse and undo it.
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
            if !snapshot.skills.contains(where: { $0.slug == overlay.slug }) { snapshot.skills.append(overlay) }
        case .skillMetadata(let slug, let tags, let scope):
            guard let index = snapshot.skills.firstIndex(where: { $0.slug == slug }) else { return false }
            if let tags { snapshot.skills[index].tags = tags }
            if let scope { snapshot.skills[index].scope = scope }
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

    private static func set(_ value: String, present: Bool, in values: inout [String]) {
        if present {
            if !values.contains(value) { values.append(value) }
        } else { values.removeAll { $0 == value } }
    }
}
