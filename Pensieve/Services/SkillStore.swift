import Foundation

/// Raised when a skill directory name resolves to something unsafe (a symlinked canonical slug
/// dir, a separator/`.`/`..`/empty component). Module-internal so deploy-side sinks can throw it too.
enum SkillStoreError: Error, Equatable {
    case invalidDirectory(String)
    case unsafeLeaf(String)
}

// MARK: - Protocol

protocol SkillStoreProtocol {
    /// Create a new skill directory and write a canonical, self-describing SKILL.md
    /// (`name`/`description` frontmatter + body). Returns the directory name (slug).
    func createSkill(name: String, description: String, body: String) throws -> String
    /// Create a skill whose slug also avoids `avoiding` — every slug a SwiftData row currently holds — so a
    /// row whose directory is missing can never be shadowed by a new directory under its own slug.
    func createSkill(name: String, description: String, body: String, avoiding: Set<String>) throws -> String
    /// Create a new slug and write a complete, already prepared SKILL.md in one write.
    func createSkill(name: String, content: String, avoiding: Set<String>) throws -> String
    /// Read the raw SKILL.md content (INCLUDING any frontmatter). Callers that want only the
    /// markdown body must strip via `SkillParser.stripFrontmatter`.
    func readBody(directoryName: String) throws -> String
    /// Read saved SKILL.md bytes from this store, without decoding or stripping a byte-order mark.
    func readData(directoryName: String) throws -> Data
    /// Rewrite an existing SKILL.md from caller-supplied parsed preservation data.
    func rewriteSkill(directoryName: String, body: String, preserving parsed: ParsedSkill,
                      fallbackName: String, fallbackDescription: String) throws -> SkillRewriteResult
    /// Write raw SKILL.md content verbatim - no frontmatter synthesis. Low-level primitive.
    func writeBody(directoryName: String, body: String) throws
    /// Delete a skill directory and its contents.
    func deleteSkill(directoryName: String) throws
    /// List all skill directory names.
    func listSkills() throws -> [String]
    /// No-follow presence of the slug's ENTRY in the skills directory, whatever its type — a regular
    /// directory, an empty one, a file, a symlink (dangling included). Throws when the parent cannot be
    /// enumerated; callers must treat a throw as "don't know" and retain.
    func slugEntryExists(_ directoryName: String) throws -> Bool
}

extension SkillStoreProtocol {
    func createSkill(name: String, content: String, avoiding: Set<String>) throws -> String {
        throw CocoaError(.featureUnsupported)
    }

    /// Existing doubles must explicitly support byte reads; never fall back to a different store or text decoding.
    func readData(directoryName: String) throws -> Data { throw CocoaError(.featureUnsupported) }

    func createSkill(name: String, description: String, body: String, avoiding: Set<String>) throws -> String {
        try createSkill(name: name, description: description, body: body)
    }

    func slugEntryExists(_ directoryName: String) throws -> Bool { throw SkillStoreError.invalidDirectory(directoryName) }
}

// MARK: - Implementation

final class SkillStore: SkillStoreProtocol {
    private let fileService: FileServiceProtocol
    private let baseDir: String

    init(fileService: FileServiceProtocol, baseDir: String = PathConstants.pensieveSkillsDir) {
        self.fileService = fileService
        self.baseDir = baseDir
    }

    func createSkill(name: String, description: String, body: String) throws -> String {
        try createSkill(name: name, description: description, body: body, avoiding: [])
    }

    func createSkill(name: String, description: String, body: String, avoiding: Set<String>) throws -> String {
        try createSkill(
            name: name,
            content: SkillSerializer.serialize(name: name, description: description, body: body),
            avoiding: avoiding
        )
    }

    func createSkill(name: String, content: String, avoiding: Set<String>) throws -> String {
        let slug = Self.slugify(name)
        let dirName = try uniqueDirectoryName(for: slug, avoiding: avoiding)
        try fileService.createDirectory(at: baseDir + "/" + dirName)
        let path = try validatedSkillDirectory(dirName) + "/SKILL.md"
        try fileService.writeFile(at: path, content: content)
        return dirName
    }

    func readBody(directoryName: String) throws -> String {
        let path = try validatedSkillDirectory(directoryName) + "/SKILL.md"
        // Leaf guard: a leaf that EXISTS but is not a regular file — a
        // symlink (even to a regular file), a directory, a FIFO/socket/device — is refused
        // before any read. A MISSING leaf falls through so readFile's natural error is
        // preserved for the common absent case (callers already handle that shape).
        if fileService.isSymlink(at: path)
            || (fileService.fileExists(at: path) && !fileService.isRegularFile(at: path)) {
            throw SkillStoreError.unsafeLeaf(directoryName)
        }
        return try fileService.readFile(at: path)
    }

    func readData(directoryName: String) throws -> Data {
        let path = try validatedSkillDirectory(directoryName) + "/SKILL.md"
        return try fileService.readRegularFileData(at: path, maximumBytes: Int.max)
    }

    @discardableResult
    func rewriteSkill(directoryName: String, body: String, preserving parsed: ParsedSkill,
                      fallbackName: String, fallbackDescription: String) throws -> SkillRewriteResult {
        let path = try validatedSkillDirectory(directoryName) + "/SKILL.md"
        let result = SkillSerializer.rewrite(
            body: body,
            preserving: parsed,
            fallbackName: fallbackName,
            fallbackDescription: fallbackDescription
        )
        guard result.didChange else { return result }
        try fileService.writeFile(at: path, content: result.content)
        return result
    }

    func writeBody(directoryName: String, body: String) throws {
        let path = try validatedSkillDirectory(directoryName) + "/SKILL.md"
        try fileService.writeFile(at: path, content: body)
    }

    func deleteSkill(directoryName: String) throws {
        try fileService.deleteDirectory(at: try validatedSkillDirectory(directoryName))
    }

    func listSkills() throws -> [String] {
        guard fileService.directoryExists(at: baseDir) else { return [] }
        return try fileService.listDirectory(at: baseDir).filter { entry in
            let skillPath = baseDir + "/" + entry + "/SKILL.md"
            return fileService.fileExists(at: skillPath)
        }
    }

    func slugEntryExists(_ directoryName: String) throws -> Bool {
        guard Self.isPathSafeSlug(directoryName) else { throw SkillStoreError.invalidDirectory(directoryName) }
        let wanted = directoryName.lowercased()
        return try fileService.listDirectory(at: baseDir).contains { $0.lowercased() == wanted }
    }

    // MARK: - Slug Generation

    static func slugify(_ name: String) -> String {
        let slug = name.lowercased()
            .replacing(/[^a-z0-9\s-]/, with: "")
            .replacing(/\s+/, with: "-")
            .replacing(/^-+|-+$/, with: "")
        return slug.isEmpty ? "skill" : slug
    }

    /// A canonical slug is exactly one normalized directory component. Keeping this check
    /// independent of filesystem state lets manifest writers reject path-bearing synced data
    /// before using a slug as a filename. Used when MINTING a new slug (install/create), which
    /// is always the slugified form — not as a gate on already-existing on-disk skill names.
    static func isCanonicalSlug(_ slug: String) -> Bool {
        !slug.isEmpty
            && !slug.utf8.contains(UInt8(ascii: "/"))
            && slug != "."
            && slug != ".."
            && slugify(slug) == slug
    }

    /// The security-relevant floor for a slug used as a manifest FILENAME (`skills/<slug>.yaml`):
    /// it must be exactly one non-traversing, non-hidden directory component free of control
    /// characters — but NOT necessarily fully slugified. A legitimately hand-placed or imported
    /// skill directory (e.g. `PDF_Tools`, `My.Skill`) is path-safe though non-canonical, and the
    /// full-snapshot writer must tolerate it rather than bricking every manifest write. Traversal
    /// (`/`, `\`, `.`, `..`, a leading dot) and control characters (which can also break the YAML
    /// scalar) are still rejected. (PLAN-19 security review.)
    static func isPathSafeSlug(_ slug: String) -> Bool {
        !slug.isEmpty
            && !slug.utf8.contains(UInt8(ascii: "/"))
            && !slug.utf8.contains(UInt8(ascii: "\\"))
            && slug != "."
            && slug != ".."
            && slug.utf8.first != UInt8(ascii: ".")
            && !slug.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// Pure path construction for render-time context. Filesystem admission still uses C7.
    static func skillDirectoryPath(slug: String, base: String) -> String? {
        guard !slug.isEmpty, !slug.utf8.contains(UInt8(ascii: "/")), slug != ".", slug != ".." else { return nil }
        return base + "/" + slug
    }

    // MARK: - Private

    /// The single C7 guard. Returns `<base>/<slug>` iff `slug` is a safe single directory
    /// component (non-empty; no `/`; not `.`/`..`) AND `<base>/<slug>` is neither a symlink nor
    /// realpaths outside `<base>`. Returns nil otherwise. PURE check — the caller decides what to
    /// do with nil (throw / skip / return 0), so a fail-safe skip site never has to catch a throw.
    static func safeSkillDirectory(slug: String, base: String, fileService: FileServiceProtocol) -> String? {
        guard let dirPath = skillDirectoryPath(slug: slug, base: base) else { return nil }
        if fileService.isSymlink(at: dirPath) { return nil }
        let realBase = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
        let realDir = URL(fileURLWithPath: dirPath).resolvingSymlinksInPath().path
        guard realDir == realBase + "/" + slug else { return nil }
        return dirPath
    }

    /// Leaf companion to `safeSkillDirectory` (Stage 12.7). Returns `<base>/<slug>/SKILL.md` iff the
    /// directory is safe (per `safeSkillDirectory`) AND the `SKILL.md` leaf is a REGULAR file. Returns
    /// nil for every other shape: an unsafe/symlinked dir, a SYMLINKED leaf, an absent leaf, a leaf that
    /// is itself a directory, or a special node (FIFO/socket/device). PURE check — the caller (the
    /// daemon reconcile passes, the heaviest unattended readers) skips on nil.
    ///
    /// `safeSkillDirectory` is dir-only: a real `skills/<slug>/` whose `SKILL.md` LEAF is a symlink
    /// pointing outside the store is still followed on read today (the C7 leaf residual). The single
    /// `isRegularFile` guard here is the load-bearing leaf check — it uses `attributesOfItem` (lstat
    /// semantics, does NOT follow the final component), so a symlinked leaf resolves as
    /// `.typeSymbolicLink` (rejected without being followed) and a FIFO/socket/device leaf is rejected
    /// too. It is deliberately NOT `fileExists`, which FOLLOWS symlinks and admits special nodes (a
    /// FIFO leaf would then hang the daemon's read). With the dir already realpath-contained by
    /// `safeSkillDirectory` and the leaf proven a regular file, the leaf's realpath is necessarily
    /// within the canonical dir — no separate realpath backstop is needed (a redundant backstop would
    /// also mask the load-bearing guard from the mutation probe).
    static func safeSkillFile(slug: String, base: String, fileService: FileServiceProtocol) -> String? {
        guard let dirPath = safeSkillDirectory(slug: slug, base: base, fileService: fileService) else { return nil }
        let filePath = dirPath + "/SKILL.md"
        guard fileService.isRegularFile(at: filePath) else { return nil }
        return filePath
    }

    /// Reject a symlinked `<baseDir>/<dirName>` (or one that realpaths outside baseDir) so a malicious
    /// pulled tree committing `skills/<slug>` as a symlinked DIRECTORY can't redirect an atomic SKILL.md
    /// write into the symlink target (C7). A symlinked LEAF is already neutralized by
    /// `writeFile(atomically:)` (it replaces the link, not its target); the dir case is the escape this
    /// closes. `dirName` is a single slug component - reject any separator, `.`/`..`, or empty too.
    private func validatedSkillDirectory(_ dirName: String) throws -> String {
        guard let path = Self.safeSkillDirectory(slug: dirName, base: baseDir, fileService: fileService) else {
            throw SkillStoreError.invalidDirectory(dirName)
        }
        return path
    }

    /// Returns a unique directory name, appending -2, -3, etc. on collision.
    private func uniqueDirectoryName(for slug: String, avoiding: Set<String>) throws -> String {
        let avoided = Set(avoiding.map { $0.lowercased() })
        func taken(_ candidate: String) -> Bool {
            avoided.contains(candidate.lowercased()) || fileService.directoryExists(at: baseDir + "/" + candidate)
        }
        if !taken(slug) { return slug }
        var counter = 2
        while taken(slug + "-\(counter)") { counter += 1 }
        return slug + "-\(counter)"
    }
}
