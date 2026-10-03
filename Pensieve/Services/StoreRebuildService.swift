import Foundation
import SwiftData

// MARK: - Result

/// The outcome of a disk + manifest -> SwiftData reconcile. `Equatable` so an idempotence test can
/// assert an all-zero second pass. `warnings` collects non-fatal anomalies: a skill file skipped for
/// missing required frontmatter, an overlay whose SKILL.md is absent (a corruption signal), and an
/// unreadable manifest (a newer schema).
struct RebuildResult: Equatable {
    var skillsInserted: Int = 0
    var skillsUpdated: Int = 0
    var skillsRemoved: Int = 0
    var categoriesInserted: Int = 0
    var categoriesUpdated: Int = 0
    var categoriesRemoved: Int = 0
    var scenariosInserted: Int = 0
    var scenariosUpdated: Int = 0
    var scenariosRemoved: Int = 0
    var deployIntentsInserted: Int = 0
    var deployIntentsUpdated: Int = 0
    var deployIntentsRemoved: Int = 0
    var warnings: [String] = []
    /// True when the rebuild BAILED because the manifest was unreadable (a newer/unsupported schema) —
    /// nothing was ingested. Distinct from per-item `warnings`. `SyncEngine` refuses to push over a store
    /// it couldn't read (a downgrade) and surfaces "update Pensieve" instead. (PLAN-08 / 08.4 review)
    var storeUnreadable: Bool = false
    /// The rebuild computed changes but its save failed. Unrelated caller edits do not set this flag.
    var saveFailed: Bool = false
}

// MARK: - Protocol

protocol StoreRebuildServiceProtocol {
    /// Reconcile SwiftData to on-disk truth (skills' frontmatter + the manifest overlay). Convergent:
    /// insert new, update changed, delete locally-orphaned; idempotent; admits ONLY skills with
    /// required frontmatter. Non-throwing — anomalies land in `RebuildResult.warnings`.
    @discardableResult
    func rebuild(fromRoot root: String, context: ModelContext) -> RebuildResult
}

// MARK: - Implementation

/// Rebuilds the local SwiftData index from the canonical `~/.pensieve` store + manifest overlay — the
/// clone-bootstrap (a fresh machine has files but an empty DB) and the post-pull refresh (PLAN-08
/// consumes both). Reads through `FileServiceProtocol` + `ManifestReadWriting` only; NO git here.
struct StoreRebuildService: StoreRebuildServiceProtocol {
    private let fileService: FileServiceProtocol
    private let manifestService: ManifestReadWriting
    private let save: (ModelContext) throws -> Void

    init(fileService: FileServiceProtocol = FileService(),
         manifestService: ManifestReadWriting = ManifestService(),
         save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.fileService = fileService
        self.manifestService = manifestService
        self.save = save
    }

    @discardableResult
    func rebuild(fromRoot root: String = Constants.pensieveBaseDir, context: ModelContext) -> RebuildResult {
        var result = RebuildResult()

        // Read the manifest ONCE. `read` throws when the manifest is unreadable — a newer/unsupported
        // schema OR a corrupt/malformed one, where strict list-shape validation throws
        // `corruptManifestFile`. The overlay is the AUTHORITY for every skill's scope/tags/cursor/origin
        // + category membership, so an
        // unreadable manifest must NOT drive a reconcile: an empty snapshot would reset every skill's
        // overlay-backed fields to defaults AND delete every category (data loss, PLAN-07 / 07.4
        // review). Bail with a warning and mutate NOTHING — preserve local state until the app is
        // upgraded to understand the newer store.
        guard let snapshot = try? manifestService.read(fromRoot: root) else {
            result.storeUnreadable = true
            result.warnings.append(
                "Manifest was unreadable (a newer schema version, or corrupt); skipped the rebuild to " +
                "avoid destroying local metadata. Update Pensieve to read this store.")
            return result
        }

        let manifestIsAuthoritative = manifestHasContent(root: root)
        let filePresentSlugs = rebuildSkills(
            root: root,
            snapshot: snapshot,
            context: context,
            allowsDeletion: manifestIsAuthoritative,
            result: &result
        )
        warnOverlaysWithoutFiles(snapshot: snapshot, filePresentSlugs: filePresentSlugs, result: &result)
        if manifestIsAuthoritative {
            rebuildCategories(snapshot: snapshot, context: context, result: &result)
        }
        rebuildDeployIntents(snapshot: snapshot, context: context, result: &result)

        // Surface a persistence failure instead of returning success counts over an unsaved store
        // (PLAN-07 / 07.4 review — the codebase's surface-don't-swallow rule).
        do {
            try save(context)
        } catch {
            result.saveFailed = true
            result.warnings.append(
                "Rebuild computed changes but saving the local store failed: \(error.localizedDescription)")
        }
        return result
    }
}

// MARK: - Skills reconcile

extension StoreRebuildService {
    /// The resolved target fields for one on-disk skill. `overlayCreatedAt` is nil when the skill has
    /// no manifest overlay — insert then uses `now`, and update never touches `createdAt` (dodging the
    /// `created_at = now` idempotence trap for overlay-less skills).
    private struct ResolvedSkillFields {
        let name: String
        let description: String
        let scope: SkillScope
        let tags: [String]
        let cursor: CursorAdapterConfig?
        let importedFrom: String?
        let installedOrigin: InstalledOrigin?
        let overlayCreatedAt: Date?
    }

    /// Convergent skills pass. Returns the set of slugs whose `skills/<slug>/SKILL.md` exists on disk
    /// (regardless of admission) — the deletion guard and the overlay-without-files signal both use it.
    private func rebuildSkills(root: String,
                               snapshot: ManifestSnapshot,
                               context: ModelContext,
                               allowsDeletion: Bool,
                               result: inout RebuildResult) -> Set<String> {
        let overlaysBySlug = Dictionary(snapshot.skills.map { ($0.slug, $0) },
                                        uniquingKeysWith: { first, _ in first })
        let existingSkills = (try? context.fetch(FetchDescriptor<Skill>())) ?? []
        let existingBySlug = Dictionary(existingSkills.map { ($0.directoryName, $0) },
                                        uniquingKeysWith: { first, _ in first })

        var filePresentSlugs = Set<String>()
        let skillsDir = root + "/skills"
        guard let skillEntries = listSkillEntries(at: skillsDir, result: &result) else {
            return Set(existingSkills.map { $0.directoryName })
        }
        for slug in skillEntries {
            let skillDirPath = root + "/skills/" + slug
            // C7: don't read through a symlinked/traversing slug dir (a pulled tree could redirect the
            // read outside the store). Preserve any existing row - do NOT delete - and skip+warn.
            if SkillStore.safeSkillDirectory(slug: slug, base: root + "/skills", fileService: fileService) == nil {
                result.warnings.append("Skipped '\(slug)': skill directory is a symlink; not reading through it.")
                filePresentSlugs.insert(slug)   // preserve any existing row; do NOT delete on a symlink
                continue
            }
            let skillMdPath = skillDirPath + "/SKILL.md"
            // Presence is lstat-shaped: a present-but-SYMLINKED leaf must neither look absent (row
            // delete) nor be read through (leaf escape). fileExists FOLLOWS links, so a
            // dangling symlink leaf needs the explicit isSymlink arm to be "present".
            guard fileService.fileExists(at: skillMdPath) || fileService.isSymlink(at: skillMdPath) else { continue }
            filePresentSlugs.insert(slug)
            guard SkillStore.safeSkillFile(slug: slug, base: root + "/skills", fileService: fileService) != nil else {
                result.warnings.append("Skipped '\(slug)': SKILL.md is not a regular file; not reading through it.")
                continue
            }

            guard let raw = try? fileService.readFile(at: skillMdPath) else {
                result.warnings.append("Skipped '\(slug)': SKILL.md exists but could not be read.")
                continue
            }
            let parsed = SkillParser.parse(raw)
            guard parsed.hasRequiredFrontmatter else {
                result.warnings.append(
                    "Skipped '\(slug)': SKILL.md is missing required frontmatter (name + description).")
                continue
            }
            upsertSkill(slug: slug, parsed: parsed, overlay: overlaysBySlug[slug],
                        existing: existingBySlug[slug], context: context, result: &result)
        }

        // Delete rows whose SKILL.md is ABSENT on disk (propagates an upstream removal). Keyed on FILE
        // PRESENCE, not admission: a present-but-degraded file is skipped+warned above, not deleted.
        // Deleting a Skill does not touch deploy records / the filesystem here; deploy cleanup belongs to the caller.
        deleteOrphanRows(
            existingSkills,
            filePresentSlugs: filePresentSlugs,
            allowsDeletion: allowsDeletion,
            context: context,
            result: &result
        )
        return filePresentSlugs
    }

    /// Distinguish a listing failure from a genuinely absent skills directory. Treating a
    /// transient failure as empty would delete every row during an authoritative rebuild.
    private func listSkillEntries(at skillsDir: String, result: inout RebuildResult) -> [String]? {
        guard fileService.directoryExists(at: skillsDir) else { return [] }
        guard let entries = try? fileService.listDirectory(at: skillsDir) else {
            result.warnings.append(
                "Couldn't list the skills directory; skipped the skill reconcile to avoid deleting rows.")
            return nil
        }
        return entries.sorted()
    }

    private func deleteOrphanRows(
        _ existingSkills: [Skill],
        filePresentSlugs: Set<String>,
        allowsDeletion: Bool,
        context: ModelContext,
        result: inout RebuildResult
    ) {
        guard allowsDeletion else { return }
        for skill in existingSkills where !filePresentSlugs.contains(skill.directoryName) {
            context.delete(skill)
            result.skillsRemoved += 1
        }
    }

    private func manifestHasContent(root: String) -> Bool {
        let manifestRoot = root + "/manifest"
        if fileService.fileExists(at: manifestRoot + "/projects.yaml") { return true }
        for directory in ["skills", "categories"] {
            if let entries = try? fileService.listDirectory(at: manifestRoot + "/" + directory),
               entries.contains(where: { $0.hasSuffix(".yaml") }) {
                return true
            }
        }
        return false
    }

    private func upsertSkill(slug: String, parsed: ParsedSkill, overlay: SkillOverlay?,
                             existing: Skill?, context: ModelContext, result: inout RebuildResult) {
        let name = parsed.name ?? slug
        let description = parsed.description ?? name   // hasRequiredFrontmatter guarantees non-empty; defensive
        // The overlay-backed fields (scope/tags/cursor/origin/createdAt) resolve three ways:
        //   • overlay PRESENT → the overlay is authoritative (the normal synced/migrated case).
        //   • overlay ABSENT but a row EXISTS → the manifest is SILENT, not authoritative-empty: PRESERVE
        //     the row's current values. Resetting to defaults would destroy metadata the manifest never
        //     spoke to — the data-loss root behind Finding C's deferred imports (a skill imported on a
        //     pre-overlay build, not yet backfilled) AND any future overlay-less row a rebuild/sync meets
        //     (PLAN-12 12.3 P1). Only name/description (from the on-disk frontmatter) update.
        //   • overlay ABSENT and NO row → a brand-new on-disk skill with no metadata yet: defaults are
        //     correct (an insert; the next migration/mutation writes its overlay).
        let fields: ResolvedSkillFields
        if let overlay {
            fields = ResolvedSkillFields(
                name: name, description: description,
                scope: overlay.scope, tags: overlay.tags, cursor: overlay.cursor,
                importedFrom: overlayImportedFrom(overlay.origin),
                installedOrigin: overlayInstalledOrigin(overlay.origin),
                overlayCreatedAt: overlay.createdAt)
        } else if let existing {
            fields = ResolvedSkillFields(
                name: name, description: description,
                scope: existing.scope, tags: existing.tags, cursor: existing.cursorConfig,
                importedFrom: existing.importedFrom,
                installedOrigin: existing.installedOrigin,
                overlayCreatedAt: nil)   // createdAt is only ever set from an overlay; leave the row's as-is
        } else {
            fields = ResolvedSkillFields(
                name: name, description: description,
                scope: .user, tags: [], cursor: nil, importedFrom: nil,
                installedOrigin: nil, overlayCreatedAt: nil)
        }
        if let existing {
            applyUpdate(to: existing, fields: fields, result: &result)
        } else {
            let createdAt = fields.overlayCreatedAt ?? Date()
            let skill = Skill(name: fields.name, skillDescription: fields.description, tags: fields.tags,
                              scope: fields.scope, directoryName: slug, cursorConfig: fields.cursor,
                              importedFrom: fields.importedFrom)
            skill.installedOrigin = fields.installedOrigin
            skill.createdAt = createdAt
            skill.updatedAt = createdAt   // git-derived last-modified is PLAN-08; here updatedAt == createdAt
            context.insert(skill)
            result.skillsInserted += 1
        }
    }

    /// Apply only changed fields; bump `updatedAt` and count iff something changed (idempotence).
    /// `createdAt` is durable: applied ONLY when an overlay is present (deterministic), never when absent.
    private func applyUpdate(to skill: Skill, fields: ResolvedSkillFields, result: inout RebuildResult) {
        var changed = false
        if skill.name != fields.name { skill.name = fields.name; changed = true }
        if skill.skillDescription != fields.description { skill.skillDescription = fields.description; changed = true }
        if skill.scope != fields.scope { skill.scope = fields.scope; changed = true }
        if skill.tags != fields.tags { skill.tags = fields.tags; changed = true }
        if skill.cursorConfig != fields.cursor { skill.cursorConfig = fields.cursor; changed = true }
        if skill.importedFrom != fields.importedFrom { skill.importedFrom = fields.importedFrom; changed = true }
        if skill.installedOrigin != fields.installedOrigin {
            skill.installedOrigin = fields.installedOrigin
            skill.resetUpdateCheckState()
            changed = true
        }
        if let overlayCreatedAt = fields.overlayCreatedAt, skill.createdAt != overlayCreatedAt {
            skill.createdAt = overlayCreatedAt
            changed = true
        }
        if changed {
            skill.updatedAt = Date()
            result.skillsUpdated += 1
        }
    }

    private func overlayImportedFrom(_ origin: SkillOrigin) -> String? {
        if case .imported(let from) = origin { return from }
        return nil
    }

    private func overlayInstalledOrigin(_ origin: SkillOrigin) -> InstalledOrigin? {
        if case .installed(let installed) = origin { return installed }
        return nil
    }

    /// An overlay slug with no `skills/<slug>/SKILL.md` is a corruption signal ("manifest has X but the
    /// skill dir is gone"). Warn only — auto-repair (re-fetch from origin) needs GitService + BETTER-4.
    private func warnOverlaysWithoutFiles(snapshot: ManifestSnapshot,
                                          filePresentSlugs: Set<String>,
                                          result: inout RebuildResult) {
        for overlay in snapshot.skills where !filePresentSlugs.contains(overlay.slug) {
            result.warnings.append(
                "Overlay for '\(overlay.slug)' has no skills/\(overlay.slug)/SKILL.md " +
                "(missing skill; re-fetch needs BETTER-4).")
        }
    }
}

// MARK: - Categories reconcile

extension StoreRebuildService {
    private func rebuildCategories(snapshot: ManifestSnapshot,
                                   context: ModelContext,
                                   result: inout RebuildResult) {
        let existingCategories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        var existingByName = Dictionary(existingCategories.map { ($0.name, $0) },
                                        uniquingKeysWith: { first, _ in first })

        for record in snapshot.categories {
            let projectKeys = Array(Set(record.projectKeys)).sorted()
            let skillSlugs = Array(Set(record.skillSlugs)).sorted()
            if let existing = existingByName.removeValue(forKey: record.name) {
                var changed = false
                if existing.projectKeys != projectKeys { existing.projectKeys = projectKeys; changed = true }
                if existing.skillSlugs != skillSlugs { existing.skillSlugs = skillSlugs; changed = true }
                if changed { result.categoriesUpdated += 1 }
            } else {
                let category = Category(name: record.name)
                category.projectKeys = projectKeys
                category.skillSlugs = skillSlugs
                context.insert(category)
                result.categoriesInserted += 1
            }
        }

        // Delete local categories absent from the manifest. Do NOT create/delete Project rows:
        // a projectKey with no locally-registered Project simply doesn't fan out (CategoryReconciler
        // skips unresolvable keys) — no path-less phantom projects.
        for category in existingByName.values {
            context.delete(category)
            result.categoriesRemoved += 1
        }
    }
}
