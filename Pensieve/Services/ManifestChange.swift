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
    case retireLocalSkill(String, String)
    case renameSkill(String, String)

    var isDeletion: Bool {
        switch self {
        case .deleteCategory, .deleteSkill: true
        default: false
        }
    }

    /// Validate before durable publication and before projecting pending edits into the window.
    /// A conflicting pending rename is refused and undone before its projection is accepted.
    func validate(in snapshot: ManifestSnapshot) throws {
        if case .createSkill(let local) = self,
           let durable = snapshot.skills.first(where: { $0.slug == local.slug }),
           !ManifestService.sameCreation(local, durable) {
            throw ManifestSaveError.createCollision(local.slug)
        }
        if case .renameSkill(let old, let new) = self {
            guard SkillStore.isPathSafeSlug(new), ManifestService.isAdmittedIntentComponent(new) else {
                throw ManifestError.corruptManifestFile("skills/" + new + ".yaml")
            }
            if snapshot.skills.contains(where: { $0.slug == old }),
               snapshot.skills.contains(where: { $0.slug != old && $0.slug.lowercased() == new.lowercased() }) {
                throw ManifestError.corruptManifestFile("skills/" + new + ".yaml")
            }
            return
        }
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
            return updateMetadata(slug, tags: tags, scope: scope, in: &snapshot)
        case .deleteSkill(let slug):
            let count = snapshot.skills.count
            snapshot.skills.removeAll { $0.slug == slug }
            return snapshot.skills.count != count
        case .renameSkill(let old, let new):
            return renameSkill(old, to: new, in: &snapshot)
        case .retireLocalSkill(let slug, let machine):
            snapshot.deployIntents.removeAll { $0.skillSlug == slug && $0.machineID == machine }
        case .retireSkill(let slug):
            snapshot.deployIntents.removeAll { $0.skillSlug == slug }
            for index in snapshot.categories.indices { snapshot.categories[index].skillSlugs.removeAll { $0 == slug } }
        default: return false
        }
        return true
    }

    private func renameSkill(_ old: String, to new: String, in snapshot: inout ManifestSnapshot) -> Bool {
        guard let index = snapshot.skills.firstIndex(where: { $0.slug == old }) else {
            return snapshot.skills.contains { $0.slug == new }
        }
        snapshot.skills[index].slug = new
        for index in snapshot.deployIntents.indices where snapshot.deployIntents[index].skillSlug == old {
            snapshot.deployIntents[index].skillSlug = new
        }
        for index in snapshot.categories.indices {
            snapshot.categories[index].skillSlugs = snapshot.categories[index].skillSlugs.map { $0 == old ? new : $0 }
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

/// A refused create's rename scopes peer-owned names to this Mac's intents. Carried names
/// also move memberships and other machines' intents, using the window's current assignments.
struct ManifestLocalIntentMove: Codable {
    let oldSlugs: Set<String>
    let newSlug: String
    let machineID: String
    let carriedSlugs: Set<String>

    init(oldSlugs: Set<String>, newSlug: String, machineID: String, carriedSlugs: Set<String> = []) {
        self.oldSlugs = oldSlugs
        self.newSlug = newSlug
        self.machineID = machineID
        self.carriedSlugs = carriedSlugs.intersection(oldSlugs)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(oldSlugs: try values.decode(Set<String>.self, forKey: .oldSlugs),
            newSlug: try values.decode(String.self, forKey: .newSlug),
            machineID: try values.decode(String.self, forKey: .machineID),
            carriedSlugs: try values.decodeIfPresent(Set<String>.self, forKey: .carriedSlugs) ?? [])
    }

    enum CodingKeys: String, CodingKey {
        case oldSlugs = "old_slugs", newSlug = "new_slug", machineID = "machine_id", carriedSlugs = "carried_slugs"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(oldSlugs.sorted(), forKey: .oldSlugs)
        try values.encode(newSlug, forKey: .newSlug)
        try values.encode(machineID, forKey: .machineID)
        try values.encode(carriedSlugs.sorted(), forKey: .carriedSlugs)
    }

    func apply(to snapshot: inout ManifestSnapshot, durable: ManifestSnapshot, local: ManifestSnapshot?,
               localIsCurrent: Bool = true, knownCreates: [SkillOverlay] = []) {
        let reusedSlugs = reusedCarriedSlugs(in: snapshot, local: local, knownCreates: knownCreates)
        for index in snapshot.deployIntents.indices
            where oldSlugs.contains(snapshot.deployIntents[index].skillSlug)
                && !reusedSlugs.contains(snapshot.deployIntents[index].skillSlug)
                && snapshot.deployIntents[index].machineID == machineID {
            snapshot.deployIntents[index].skillSlug = newSlug
        }
        for intent in local?.deployIntents ?? [] where intent.skillSlug == newSlug && intent.machineID == machineID {
            if !snapshot.deployIntents.contains(intent) { snapshot.deployIntents.append(intent) }
        }
        if localIsCurrent, let local,
           let renamed = local.skills.first(where: { $0.slug == newSlug }),
           !durable.skills.contains(where: { $0.slug == newSlug && ManifestService.sameCreation($0, renamed) }) {
            removeReusedLeftovers(from: &snapshot, local: local, reusedSlugs: reusedSlugs)
        }
        if !carriedSlugs.isEmpty {
            applyCarried(to: &snapshot, local: local, carriedSlugs: carriedSlugs.subtracting(reusedSlugs))
        }
    }

    func reusesCarriedName(in snapshot: ManifestSnapshot, knownCreates: [SkillOverlay]) -> Bool {
        !reusedCarriedSlugs(in: snapshot, local: nil, knownCreates: knownCreates).isEmpty
    }

    /// Until the renamed creation reaches disk, rows distinguish the replacement's own
    /// values from old-name leftovers. Afterwards a peer can legitimately request that name.
    private func removeReusedLeftovers(from snapshot: inout ManifestSnapshot, local: ManifestSnapshot,
                                       reusedSlugs: Set<String>) {
        for index in snapshot.categories.indices {
            let window = local.categories.first { $0.name == snapshot.categories[index].name }
            snapshot.categories[index].skillSlugs.removeAll {
                reusedSlugs.contains($0) && window?.skillSlugs.contains($0) != true
            }
        }
        snapshot.deployIntents.removeAll { reusedSlugs.contains($0.skillSlug) && !local.deployIntents.contains($0) }
    }

    /// Another creation can hold a freed name on disk, in the window or in another queue
    /// entry. A whole-row save of this same creation still belongs to the rename.
    private func reusedCarriedSlugs(in snapshot: ManifestSnapshot, local: ManifestSnapshot?,
                                    knownCreates: [SkillOverlay]) -> Set<String> {
        let renamed = local?.skills.first { $0.slug == newSlug } ?? snapshot.skills.first { $0.slug == newSlug }
        let visible = snapshot.skills + (local?.skills ?? []) + knownCreates
        return Set(visible.filter {
            guard carriedSlugs.contains($0.slug) else { return false }
            guard let renamed else { return true }
            return !ManifestService.sameCreation($0, renamed)
        }.map(\.slug))
    }

    private func applyCarried(to snapshot: inout ManifestSnapshot, local: ManifestSnapshot?, carriedSlugs: Set<String>) {
        guard let local else {
            for index in snapshot.categories.indices {
                snapshot.categories[index].skillSlugs = snapshot.categories[index].skillSlugs.map {
                    carriedSlugs.contains($0) ? newSlug : $0
                }
            }
            for index in snapshot.deployIntents.indices where carriedSlugs.contains(snapshot.deployIntents[index].skillSlug) {
                snapshot.deployIntents[index].skillSlug = newSlug
            }
            return
        }
        // Old durable memberships can outlive an unassignment of the new name. Only the
        // window knows whether the renamed skill still belongs in each category.
        for index in snapshot.categories.indices {
            snapshot.categories[index].skillSlugs.removeAll { carriedSlugs.contains($0) }
            if local.categories.contains(where: {
                $0.name == snapshot.categories[index].name && $0.skillSlugs.contains(newSlug)
            }), !snapshot.categories[index].skillSlugs.contains(newSlug) {
                snapshot.categories[index].skillSlugs.append(newSlug)
            }
        }
        snapshot.deployIntents.removeAll { carriedSlugs.contains($0.skillSlug) }
        for intent in local.deployIntents where intent.skillSlug == newSlug {
            if !snapshot.deployIntents.contains(intent) { snapshot.deployIntents.append(intent) }
        }
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
    var collision: SkillOverlay?
    var intentMove: ManifestLocalIntentMove?

    var createdSkills: [SkillOverlay] {
        fields.compactMap {
            if case .change(.createSkill(let skill)) = $0 { return skill }
            return nil
        }
    }

    func project(onto snapshot: inout ManifestSnapshot, keepingLocalCreates: Bool = false,
                 knownCreates: [SkillOverlay] = [], local: ManifestSnapshot? = nil,
                 durable: ManifestSnapshot? = nil) {
        let durable = durable ?? snapshot
        for field in fields { project(field, onto: &snapshot, keepingLocalCreates: keepingLocalCreates) }
        intentMove?.apply(to: &snapshot, durable: durable, local: local ?? cachedLocal,
                          localIsCurrent: local != nil, knownCreates: knownCreates)
    }

    func project(_ field: Field, onto snapshot: inout ManifestSnapshot, keepingLocalCreates: Bool = false) {
        if case .change(let change) = field {
            if case .createSkill(let original) = change {
                projectCreate(original, onto: &snapshot, keepingLocalCreates: keepingLocalCreates)
                return
            }
            if collision != nil, !keepingLocalCreates, case .skillMetadata = change { return }
            do { try change.validate(in: snapshot) } catch { return }
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

    private func projectCreate(_ original: SkillOverlay, onto snapshot: inout ManifestSnapshot,
                               keepingLocalCreates: Bool) {
        let current: SkillOverlay
        if let cachedLocal {
            guard let local = cachedLocal.skills.first(where: { $0.slug == original.slug }) else { return }
            current = local
        } else { current = original }
        if keepingLocalCreates {
            snapshot.skills.removeAll { $0.slug == current.slug }
        }
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
