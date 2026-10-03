import CryptoKit
import Foundation

// MARK: - Implementation

struct ManifestService: ManifestReadWriting {
    static let currentSchemaVersion = 5

    let fileService: FileServiceProtocol
    private let supportedSchemaVersion: Int

    init(fileService: FileServiceProtocol = FileService(),
         supportedSchemaVersion: Int = Self.currentSchemaVersion) {
        self.fileService = fileService
        self.supportedSchemaVersion = supportedSchemaVersion
    }

    // MARK: Write (idempotent, prunes stale)

    func write(_ snapshot: ManifestSnapshot, toRoot root: String) throws {
        let manifestDir = root + "/manifest"
        try refuseNewerExistingManifest(at: manifestDir)
        try validateSnapshotForWrite(snapshot)

        // Whole tree built in a SIBLING temp OUTSIDE the repo (sync's `git add -A` can't push a partial build;
        // same volume for `replaceItem`'s atomic swap); UUID-unique temp so concurrent writers never collide.
        let parent = (root as NSString).deletingLastPathComponent
        let base = (root as NSString).lastPathComponent
        let tmpDir = parent + "/" + base + ".manifest-build-" + UUID().uuidString + ".tmp"
        let categoriesDir = tmpDir + "/categories"
        let scenariosDir = tmpDir + "/scenarios"
        let skillsDir = tmpDir + "/skills"
        let deploysDir = tmpDir + "/deploys"

        do {
            for directory in [categoriesDir, scenariosDir, skillsDir, deploysDir] {
                try fileService.createDirectory(at: directory)
            }
            try fileService.writeFile(
                at: tmpDir + "/manifest.yaml",
                content: "schema_version: \(supportedSchemaVersion)\n"
            )
            for category in snapshot.categories {
                try fileService.writeFile(
                    at: categoriesDir + "/" + Self.categoryFileName(category.name),
                    content: Self.serializeCategory(category)
                )
            }
            try carryScenarioFiles(from: manifestDir + "/scenarios", to: scenariosDir)
            for skill in snapshot.skills {
                try fileService.writeFile(
                    at: skillsDir + "/" + skill.slug + ".yaml",
                    content: Self.serializeSkillOverlay(skill)
                )
            }
            try writeDeployIntents(snapshot.deployIntents, to: deploysDir)
            try fileService.writeFile(
                at: tmpDir + "/projects.yaml",
                content: Self.serializeProjects(snapshot.projects)
            )
            if !fileService.directoryExists(at: root) {
                try fileService.createDirectory(at: root)
            }
            try fileService.replaceItem(at: manifestDir, with: tmpDir)
        } catch {
            try? fileService.deleteDirectory(at: tmpDir)
            throw error
        }
    }

    private func validateSnapshotForWrite(_ snapshot: ManifestSnapshot) throws {
        try Self.validateSkillSlugs(snapshot.skills)
        try Self.validateDeployIntents(snapshot.deployIntents)
        if supportedSchemaVersion < 5,
           snapshot.deployIntents.contains(where: { $0.projectKey != nil }) {
            throw ManifestError.corruptManifestFile("deploys")
        }
    }

    /// Write-side downgrade guard: refuse iff the tree PARSES newer; absent/unreadable proceeds (heals corrupt).
    private func refuseNewerExistingManifest(at manifestDir: String) throws {
        guard let schema = try? readSchema(from: manifestDir), schema > supportedSchemaVersion else { return }
        throw ManifestError.unsupportedSchema(found: schema, supported: supportedSchemaVersion)
    }

    // MARK: Read (CheckedYAMLLoader; dedup; keyed by in-file identity)

    func read(fromRoot root: String) throws -> ManifestSnapshot {
        let manifestDir = root + "/manifest"
        let schema = try readSchema(from: manifestDir)
        if schema > supportedSchemaVersion {
            throw ManifestError.unsupportedSchema(found: schema, supported: supportedSchemaVersion)
        }

        return ManifestSnapshot(
            schemaVersion: schema,
            categories: try readCategories(from: manifestDir).sorted { $0.name < $1.name },

            projects: try readProjects(from: manifestDir).sorted { $0.identityKey < $1.identityKey },
            skills: try readSkills(from: manifestDir).sorted { $0.slug < $1.slug },
            deployIntents: schema >= 4
                ? try readDeployIntents(from: manifestDir, schemaVersion: schema)
                : []
        )
    }

    private func readSchema(from manifestDir: String) throws -> Int {
        let path = manifestDir + "/manifest.yaml"
        guard fileService.fileExists(at: path) else { return supportedSchemaVersion }
        guard let top = try? fileService.readFile(at: path),
              let obj = (try? CheckedYAMLLoader.load(yaml: top)) as? [String: Any],
              let schema = obj["schema_version"] as? Int else {
            throw ManifestError.corruptManifestFile("manifest.yaml")
        }
        return schema
    }

    private func readCategories(from manifestDir: String) throws -> [CategoryRecord] {
        var categories: [CategoryRecord] = []
        let categoriesDir = manifestDir + "/categories"
        guard fileService.directoryExists(at: categoriesDir) else { return [] }
        for entry in try fileService.listDirectory(at: categoriesDir) where entry.hasSuffix(".yaml") {
            guard let content = try? fileService.readFile(at: categoriesDir + "/" + entry),
                  let obj = (try? CheckedYAMLLoader.load(yaml: content)) as? [String: Any],
                  let name = obj["name"] as? String else {
                throw ManifestError.corruptManifestFile("categories/" + entry)
            }
            categories.append(CategoryRecord(
                name: name,
                projectKeys: try Self.requireStringList(obj, "project_keys", file: "categories/" + entry),
                skillSlugs: try Self.requireStringList(obj, "skill_slugs", file: "categories/" + entry)
            ))
        }
        return categories
    }

    /// Legacy definitions belong to older builds. Keep opaque regular-file bytes in the atomic
    /// replacement tree, and never traverse a symlinked scenarios directory or entry.
    private func carryScenarioFiles(from source: String, to destination: String) throws {
        try fileService.copyRegularFiles(fromDirectory: source, toDirectory: destination)
    }

    private func readSkills(from manifestDir: String) throws -> [SkillOverlay] {
        var skills: [SkillOverlay] = []
        let skillsDir = manifestDir + "/skills"
        if fileService.directoryExists(at: skillsDir) {
            for entry in try fileService.listDirectory(at: skillsDir) where entry.hasSuffix(".yaml") {
                guard let content = try? fileService.readFile(at: skillsDir + "/" + entry),
                      let obj = (try? CheckedYAMLLoader.load(yaml: content)) as? [String: Any],
                      let slug = obj["slug"] as? String else {
                    throw ManifestError.corruptManifestFile("skills/" + entry)
                }
                let createdAt = (obj["created_at"] as? String).flatMap { Self.parseDate($0) }
                    ?? (obj["created_at"] as? Date)
                    ?? Date(timeIntervalSince1970: 0)
                let scope = SkillScope(rawValue: (obj["scope"] as? String) ?? "user") ?? .user
                var origin: SkillOrigin = .authored
                if let originMap = obj["origin"] as? [String: Any], let kind = originMap["kind"] as? String {
                    switch kind {
                    case "imported":
                        origin = .imported(from: (originMap["imported_from"] as? String) ?? "")
                    case "installed":
                        origin = .installed(Self.parseInstalledOrigin(originMap))
                    default:
                        origin = .authored
                    }
                }
                var cursor: CursorAdapterConfig?
                if let cursorMap = obj["cursor"] as? [String: Any] {
                    let globs = (cursorMap["globs"] as? [Any])?.compactMap { $0 as? String }
                    cursor = CursorAdapterConfig(
                        description: cursorMap["description"] as? String,
                        globs: globs.map { Array(Set($0)).sorted() },
                        alwaysApply: (cursorMap["always_apply"] as? Bool) ?? false
                    )
                }
                skills.append(SkillOverlay(
                    slug: slug,
                    createdAt: createdAt,
                    scope: scope,
                    tags: try Self.requireStringList(obj, "tags", file: "skills/" + entry),
                    cursor: cursor,
                    agents: try Self.requireStringList(obj, "agents", file: "skills/" + entry),
                    origin: origin
                ))
            }
        }
        return skills
    }

    private func readProjects(from manifestDir: String) throws -> [ProjectIdentityRecord] {
        let path = manifestDir + "/projects.yaml"
        guard fileService.fileExists(at: path) else { return [] }
        guard let content = try? fileService.readFile(at: path) else {
            throw ManifestError.corruptManifestFile("projects.yaml")
        }
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        guard let obj = (try? CheckedYAMLLoader.load(yaml: content)) as? [String: Any] else {
            throw ManifestError.corruptManifestFile("projects.yaml")
        }
        var parsed: [ProjectIdentityRecord] = []
        for item in obj["projects"] as? [Any] ?? [] {
            guard let p = item as? [String: Any],
                  let key = p["identity_key"] as? String,
                  let kind = p["identity_kind"] as? String,
                  let name = p["name"] as? String else { continue }
            parsed.append(ProjectIdentityRecord(identityKey: key, identityKind: kind, name: name))
        }
        return Self.dedupProjectsByIdentity(parsed)
    }

}
// MARK: - Filenames, serialization, and helpers (stateless)
extension ManifestService {
    // MARK: - Safe filenames

    static func categoryFileName(_ name: String) -> String {
        let prefix = slugify(name, fallback: "cat")
        return prefix + "-" + sha256Hex16(name) + ".yaml"
    }

    private static func slugify(_ value: String, fallback: String) -> String {
        let slug = value.lowercased()
            .replacing(/[^a-z0-9\s-]/, with: "")
            .replacing(/\s+/, with: "-")
            .replacing(/^-+|-+$/, with: "")
        return slug.isEmpty ? fallback : slug
    }

    private static func sha256Hex16(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    // MARK: - Serialization (canonical: sorted, one item per line, oracle-quoted)

    static func serializeCategory(_ category: CategoryRecord) -> String {
        var lines: [String] = []
        lines.append("name: \(SkillSerializer.quotedScalar(category.name))")
        appendBlockList(&lines, key: "project_keys", values: category.projectKeys)
        appendBlockList(&lines, key: "skill_slugs", values: category.skillSlugs)
        return lines.joined(separator: "\n") + "\n"
    }

    static func serializeSkillOverlay(_ skill: SkillOverlay) -> String {
        var lines: [String] = []
        lines.append("slug: \(SkillSerializer.quotedScalar(skill.slug))")
        lines.append("created_at: \(SkillSerializer.quotedScalar(iso8601Write.string(from: skill.createdAt)))")
        lines.append("scope: \(skill.scope.rawValue)")
        appendBlockList(&lines, key: "tags", values: skill.tags)
        appendBlockList(&lines, key: "agents", values: skill.agents)
        lines.append("origin:")
        switch skill.origin {
        case .authored:
            lines.append("  kind: authored")
        case .imported(let from):
            lines.append("  kind: imported")
            lines.append("  imported_from: \(SkillSerializer.quotedScalar(from))")
        case .installed(let installed):
            lines.append("  kind: installed")
            lines.append("  repo: \(flowQuoted(installed.repo))")
            lines.append("  path: \(flowQuoted(installed.path))")
            lines.append("  ref: \(flowQuoted(installed.ref))")
            lines.append("  installed_commit: \(flowQuoted(installed.installedCommit))")
            lines.append("  installed_tree: \(flowQuoted(installed.installedTree))")
            lines.append("  content_hash: \(flowQuoted(installed.contentHash))")
            lines.append("  installed_at: \(flowQuoted(iso8601Write.string(from: installed.installedAt)))")
            lines.append("  updated_at: \(flowQuoted(iso8601Write.string(from: installed.updatedAt)))")
        }
        if let cursor = skill.cursor {
            lines.append("cursor:")
            if let description = cursor.description {
                lines.append("  description: \(SkillSerializer.quotedScalar(description))")
            }
            lines.append("  always_apply: \(cursor.alwaysApply)")
            if let globs = cursor.globs {
                lines.append("  globs:")
                for glob in globs.sorted() {
                    lines.append("    - \(SkillSerializer.quotedScalar(glob))")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func serializeProjects(_ projects: [ProjectIdentityRecord]) -> String {
        var lines: [String] = []
        lines.append("projects:")
        for project in projects.sorted(by: { $0.identityKey < $1.identityKey }) {
            lines.append("  - {identity_key: \(flowQuoted(project.identityKey)), "
                + "identity_kind: \(flowQuoted(project.identityKind)), name: \(flowQuoted(project.name))}")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Flow-context scalar: ALWAYS double-quoted + escaped (unlike `quotedScalar`, unsafe inside a flow map).
    /// Routes through the shared escaper so control/break characters in untrusted values (a skill's repo
    /// `path`/`ref`) cannot corrupt the manifest. (PLAN-19 security review.)
    static func flowQuoted(_ value: String) -> String {
        "\"\(SkillSerializer.escapeForDoubleQuoted(value))\""
    }

    /// Collapse duplicate-`identity_key` records to the lexicographically-first `(name, kind)` winner, so clones converge. (§A)
    static func dedupProjectsByIdentity(_ records: [ProjectIdentityRecord]) -> [ProjectIdentityRecord] {
        Dictionary(records.map { ($0.identityKey, $0) }) { first, second in
            (second.name, second.identityKind) < (first.name, first.identityKind) ? second : first
        }.map { $0.value }
    }

    // MARK: - Helpers

    /// One item per line (block sequence), sorted. An empty list emits a bare `key:` (null), which
    /// `requireStringList` reads back as `[]`. Never an inline flow list (`[a, b]`).
    static func appendBlockList(_ lines: inout [String], key: String, values: [String]) {
        lines.append("\(key):")
        for value in values.sorted() {
            lines.append("  - \(SkillSerializer.quotedScalar(value))")
        }
    }

    /// Membership fields (`project_keys`/`skill_slugs` on a category; `tags`/`agents` on a skill overlay)
    /// DRIVE an overwrite of live state in StoreRebuildService. A scalar-where-list corruption (or a list
    /// with a non-string element) reads as [] under the tolerant `dedupSorted`, silently emptying (then
    /// pushing) the set. We strict-validate SHAPE — throw (fail-safe) — while staying tolerant on
    /// additive scalar fields for forward-compat. Absent OR YAML-null = [] (Pensieve serializes an empty
    /// list as a bare `key:` → NSNull; treating that as corrupt would reject our OWN output — see 10.1 note).
    private static func requireStringList(_ obj: [String: Any], _ key: String, file: String) throws -> [String] {
        guard let raw = obj[key], !(raw is NSNull) else { return [] }   // absent OR null = empty set (legit)
        guard let items = raw as? [Any] else { throw ManifestError.corruptManifestFile(file) }   // scalar = corrupt
        var strings: [String] = []
        for item in items {
            guard let str = item as? String else { throw ManifestError.corruptManifestFile(file) }   // non-string elem
            strings.append(str)
        }
        return Array(Set(strings)).sorted()
    }

    /// Writer formatter: fractional seconds so a real SwiftData `Date()` (sub-second precision)
    /// round-trips exactly (PLAN-07 / 07.3 review).
    private static let iso8601Write: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Reader fallback: a fractional-only `ISO8601DateFormatter` REFUSES a whole-second string, so we
    /// also keep a non-fractional parser to tolerate legacy/hand-written overlays.
    private static let iso8601ReadPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseDate(_ value: String) -> Date? {
        iso8601Write.date(from: value) ?? iso8601ReadPlain.date(from: value)
    }
}
