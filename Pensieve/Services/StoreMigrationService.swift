import Foundation
import SwiftData

// MARK: - Result

struct MigrationResult: Equatable {
    var skillsMigrated: Int = 0
    var manifestWritten: Bool = false
    var warnings: [String] = []
}

// MARK: - Protocol

protocol StoreMigrationServiceProtocol {
    /// One-time, idempotent backfill: normalize every owned skill's SKILL.md frontmatter, backfill the
    /// SwiftData row from the more-authoritative source (origin-aware), and write the baseline manifest.
    /// Non-throwing — anomalies land in `MigrationResult.warnings`. Safe to call on every launch.
    @discardableResult
    func migrateIfNeeded(fromRoot root: String, context: ModelContext) -> MigrationResult
}

// MARK: - Implementation

/// Brings every existing (owned) skill up to the self-describing model so `~/.pensieve` is a complete,
/// rebuildable source of truth (PLAN-07): each SKILL.md gains `name`/`description` YAML frontmatter, the
/// SwiftData row is backfilled from the more-authoritative source WITHOUT losing a file-only
/// description, and the baseline manifest overlay is written. Idempotent (no write when the file is
/// already canonical). NO git (PLAN-08).
///
/// Coupling: `skillStore.baseDir` MUST be `root + "/skills"` — the composing write targets the store's
/// baseDir while the read + manifest use `root`. Production wires both from `Constants`; tests construct
/// both over the same temp root.
struct StoreMigrationService: StoreMigrationServiceProtocol {
    private let fileService: FileServiceProtocol
    private let manifestService: ManifestSnapshotting
    private let skillStore: SkillStoreProtocol

    init(fileService: FileServiceProtocol = FileService(),
         manifestService: ManifestSnapshotting = ManifestService(),
         skillStore: SkillStoreProtocol = SkillStore(fileService: FileService())) {
        self.fileService = fileService
        self.manifestService = manifestService
        self.skillStore = skillStore
    }

    @discardableResult
    func migrateIfNeeded(fromRoot root: String = Constants.pensieveBaseDir,
                         context: ModelContext) -> MigrationResult {
        var result = MigrationResult()
        // Bail on a store read failure — do NOT let a transient fetch error masquerade as "zero skills"
        // and then write an EMPTY baseline manifest that prunes every overlay (PLAN-07 / 07.5 review).
        let skills: [Skill]
        do {
            skills = try context.fetch(FetchDescriptor<Skill>())
        } catch {
            result.warnings.append(
                "Migration skipped: could not read the local store: \(error.localizedDescription)")
            return result
        }

        for skill in skills where migrateSkill(skill, root: root, result: &result) {
            result.skillsMigrated += 1
        }

        // Persist row backfills BEFORE snapshotting for the manifest.
        do {
            try context.save()
        } catch {
            result.warnings.append(
                "Migration backfilled rows but saving the local store failed: \(error.localizedDescription)")
        }

        // Baseline manifest — idempotent whole-tree write from the now-backfilled SwiftData.
        do {
            try manifestService.write(manifestService.snapshot(from: context), toRoot: root)
            result.manifestWritten = true
        } catch {
            result.warnings.append("Failed to write the baseline manifest: \(error.localizedDescription)")
        }
        return result
    }
}

// MARK: - Per-skill migration

extension StoreMigrationService {
    /// Returns true if the skill was touched (row backfilled and/or its SKILL.md normalized).
    private func migrateSkill(_ skill: Skill, root: String, result: inout MigrationResult) -> Bool {
        let skillDir = root + "/skills/" + skill.directoryName
        // C7: a symlinked/traversing slug dir must not be read through - a pulled tree could redirect the
        // read outside the store. Skip+warn (mirroring the rebuild rejection) before the read.
        if SkillStore.safeSkillDirectory(
                slug: skill.directoryName, base: root + "/skills", fileService: fileService) == nil {
            result.warnings.append(
                "Skipped '\(skill.directoryName)': skill directory is a symlink; not migrated.")
            return false
        }
        guard SkillStore.safeSkillFile(
                slug: skill.directoryName, base: root + "/skills", fileService: fileService) != nil else {
            result.warnings.append(
                "Skipped '\(skill.directoryName)': SKILL.md is not a safe regular file — not migrated.")
            return false
        }
        let skillMdPath = skillDir + "/SKILL.md"
        // Skip + warn on a missing/unreadable SKILL.md — do NOT treat it as an empty body and fabricate
        // a canonical file (that would destroy real bytes we failed to read AND clobber a file-only
        // description with the name fallback — PLAN-07 / 07.5 review). Only migrate what we can read.
        let raw: String
        do {
            raw = try fileService.readFile(at: skillMdPath)
        } catch {
            result.warnings.append(
                "Skipped '\(skill.directoryName)': SKILL.md is missing or unreadable — not migrated.")
            return false
        }
        let parsed = SkillParser.parse(raw)

        let name = resolveName(skill: skill, parsed: parsed)
        let description = resolveDescription(skill: skill, parsed: parsed, name: name)

        var touched = normalizeModelIdentity(skill, name: name, description: description)

        // A decoded identity that already matches needs neither a split nor a rewrite. In particular,
        // an otherwise safe flow mapping must not warn forever merely because it is not spliceable.
        guard parsed.name != name || parsed.description != description else { return touched }

        // `parse` deliberately falls back to whole-content-as-body when fenced YAML is not admissible.
        // Migration must not feed that fallback to the canonical writer: doing so would wrap the complete
        // original document inside new frontmatter. A line-delimited document that did not yield preserved
        // frontmatter is therefore left unchanged, just like a parsed block whose entry split is untrustworthy.
        guard frontmatterIsSafeToNormalize(
            raw: raw, parsed: parsed, directoryName: skill.directoryName, result: &result
        ) else { return touched }

        // Normalize only the identity entries. An untrustworthy split is left byte-for-byte unchanged:
        // migration may skip normalization, but it may never make data loss the fallback.
        guard let desired = SkillSerializer.normalizeIdentity(
            name: name,
            description: description,
            parsed: parsed
        ) else {
            result.warnings.append(
                "Skipped '\(skill.directoryName)': frontmatter could not be split safely — not normalized.")
            return touched
        }
        if raw != desired {
            do {
                try skillStore.writeBody(directoryName: skill.directoryName, body: desired)
                touched = true
            } catch {
                result.warnings.append(
                    "Failed to normalize SKILL.md for '\(skill.directoryName)': \(error.localizedDescription)")
            }
        }
        return touched
    }

    private func normalizeModelIdentity(_ skill: Skill, name: String, description: String) -> Bool {
        var touched = false
        if skill.name != name { skill.name = name; touched = true }
        if skill.skillDescription != description { skill.skillDescription = description; touched = true }
        return touched
    }

    private func frontmatterIsSafeToNormalize(
        raw: String,
        parsed: ParsedSkill,
        directoryName: String,
        result: inout MigrationResult
    ) -> Bool {
        let strippedBody = SkillParser.stripFrontmatter(raw)
        guard parsed.preservedFrontmatter != nil
                || strippedBody == SkillParser.canonicalBody(raw) else {
            result.warnings.append(
                "Skipped '\(directoryName)': frontmatter could not be split safely — not normalized.")
            return false
        }
        return true
    }

    /// Origin-aware name precedence. A legacy IMPORTED skill stored its directory entry as `name`, so
    /// the file's frontmatter `name` is more authoritative; an AUTHORED skill's `name` is the user's own
    /// input, so SwiftData wins. `directoryName` (non-empty since the 07.2 slug hardening) is the final
    /// fallback — the resolved name is therefore always non-empty.
    private func resolveName(skill: Skill, parsed: ParsedSkill) -> String {
        if skill.importedFrom != nil, parsed.hasRequiredFrontmatter {
            return firstNonEmpty(parsed.name, skill.name, skill.directoryName)
        }
        return firstNonEmpty(skill.name, parsed.name, skill.directoryName)
    }

    /// Description precedence is origin-independent: a real SwiftData description wins; else the file's
    /// (the legacy-import case, `skillDescription == ""` with the file carrying it); else the resolved
    /// name (the non-empty fallback the 07.4 rebuild requires). A Cursor-only description rides the
    /// overlay's `cursor.description`, not the SKILL.md `description`.
    private func resolveDescription(skill: Skill, parsed: ParsedSkill, name: String) -> String {
        firstNonEmpty(skill.skillDescription, parsed.description, name)
    }

    private func firstNonEmpty(_ values: String?...) -> String {
        for value in values where !(value ?? "").isEmpty {
            return value ?? ""
        }
        return ""
    }
}
